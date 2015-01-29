
=head1 NAME

PopManipulations - Functions for biopop

=head1 SYNOPSIS

use B<PopMan::Subs>;

=cut
# MK method is broken: change to comma-delimited way of specifying in group and out groups.
use strict;    # Still on 5.10, so need this for strict
use warnings;
use 5.010;
use Bio::AlignIO;
use Bio::Align::DNAStatistics;

#use Bio::PopGen::IO;
use FindBin;                # Find the location of PopGenStatistics
use lib "$FindBin::Bin";    # to use it as a lib path
use PopGenStatistics;
use Bio::PopGen::Utilities;
use Bio::PopGen::Statistics;
use Bio::PopGen::Population;
use Algorithm::Numerical::Sample qw(sample);
use List::Util qw(shuffle sum);
#use Math::Random::MT::Auto qw(rand);
use Statistics::Basic qw(:all);

use Data::Dumper;

# Package global variables
my ($opts,     $flags,       $aln_file, $aln,         $in,
    $pop,      $sample_size, $stat_obj, @stats,       $sim,
    $sim_type, @ingroups,     @outgroups, $dist_method, $dna_stats,
    $pop_stats, @var_sites, @exgroups, $ingroup, $outgroup
);

my %opt_dispatch = (
    'stats'    => \&_print_stats,
    'mismatch' => \&_print_mismatch_distr,
    'simmk'    => \&_sim_mk,
    'distance' => \&_print_distance,
    'kaks'     => \&_print_kaks_calc,
    'pi', => \&_print_diversity,
    'varsites', => \&_print_num_snps,
    'heterozygosity' => \&_print_heterozygosity,
    'mutrec' => \&_mutation_or_recombination
);

# The following options cannot be used along with distance or kaks opts
my @popgen_list = qw(stats mismatch simmk);

################################################################################
# Subroutines
################################################################################

## TODO DNAStatistics subs

sub initialize {
    ($opts, $flags) = @_;
#    print Dumper($flags);

    $aln_file = shift @ARGV
        || "STDIN";    # If no more arguments were given on the command line,
                       # assume we're getting input from standard input

    my $in_format = $flags->{"input"} // 'clustalw';

    if ($aln_file eq "STDIN") {    # We're getting input from STDIN
        $in = Bio::AlignIO->new(-format => $in_format, -fh => \*STDIN);
    }
    else {                           # Filename, or '-', was given
        $in = Bio::AlignIO->new(
            -format => $in_format,
            -file   => "<$aln_file"
       );
    }

    $aln = $in->next_aln; 

    $sample_size = $flags->{"sample_size"} // undef;
#    @ingroups     = split /\s+,\s+/, join ',', @{ $opts->{"ingroup"} }     // undef if $opts->{"ingroup"};;
#    @outgroups    = split /\s+,\s+/, join ',', @{ $opts->{"outgroup"} }    // undef if $opts->{"outgroup"};
#    @exgroups    = split /\s+,\s+/, join ',', @{ $opts->{"exclude"} }    // undef if $opts->{"exclude"};
    $dist_method = $flags->{"dist-method"} // undef;
    if ($opts->{"distance"} || $opts->{"kaks"}) {
        die
            "Cannot use distance or kaks options together with any of the following: @popgen_list\n"
            if (%$opts ~~ @popgen_list);
        $dna_stats = Bio::Align::DNAStatistics->new();
    }
    else {
        $pop = Bio::PopGen::Utilities->aln_to_population(
            -alignment           => $aln,
            -include_monomorphic => 1,
            -site_model          => 'all'
       );

        $stat_obj = PopGenStatistics->new();
	$pop_stats = Bio::PopGen::Statistics->new();
    }
#    print Dumper(\@ingroups);
}

# sub write_out {
#
# }

sub can_handle {
    my $option = shift;
    return defined($opt_dispatch{$option});
}

sub handle_opt {
    my $option = shift;

    # This passes option name to all functions
    $opt_dispatch{$option}->($option);
}

sub _parse_ingroup {
    return split(/,/, join(',', @{ $opts->{"ingroup"} }));
}

sub _parse_outgroup {
    return split(/,/, join(',', @{ $opts->{"outgroup"} }));
}

## Internal ##

sub _parse_stats {
    return split(/,/, join(',', @{ $opts->{"stats"} }));

    #     warn "Will print the following statistics: \n";
    #     warn "$_\n" foreach (@stats);
}

sub _print_stats {
    @stats = _parse_stats();
    my $len = $aln->length();

    foreach my $stat (@stats) {
        $stat = lc($stat);

        given ($stat) {
            when (/^(pi)|(theta)$/) {
                printf "$stat:\t%.6f\n", $stat_obj->$stat($pop, $len);
            }
            when ("tajima_d") {
                printf "tajima_D:\t%.6f\n", $stat_obj->tajima_D($pop);
            }
            when ("mk") { _mk_counts(); }
        }
    }
}

sub _print_mismatch_distr {
    my $num_seq = $aln->num_sequences();

    my @seqs;
    foreach my $seq ($aln->each_seq) {
        push @seqs, $seq;
    }
    for (my $i = 0; $i < $num_seq - 1; $i++) {
        for (my $j = $i + 1; $j < $num_seq; $j++) {
            my $new = Bio::SimpleAlign->new();
            $new->add_seq($seqs[$i]);
            $new->add_seq($seqs[$j]);
            printf "%.4f\n", (100 - $new->percentage_identity) / 100;
        }
    }
}

sub _best_sample_size {
    my @group = @_;

    # Checks if $sample_size was defined previously.
    # If it was, make sure it does not exceed the size of the group
    # If it was not, use the size of the group
    return
          ($sample_size)
        ? ($sample_size > @group)
            ? @group
            : $sample_size
        : @group;
}

sub __in_group { # internal methods
    my ($id, $ref) = @_;
    foreach my $item (@$ref) {
	return 1 if $id eq $item;
    }
    return 0;
}

sub __is_gap { # internal methods
    my $ref = shift @_;
    foreach my $item (@$ref) {
	return 1 if $item eq '-';
    }
    return 0;
}


sub _mutation_or_recombination {
    @ingroups = _parse_ingroup(); #print Dumper(\@ingroups); exit;
    @outgroups = _parse_outgroup();
    die "Error: ingroup and outgroup options required when using Mut-Rec test.\n"
        unless (@ingroups && @outgroups);

    my $in_group  = Bio::PopGen::Population->new();
    my $out_group = Bio::PopGen::Population->new();
    my (@out, @in, @ex);
    for my $ind ($pop->get_Individuals) {
        push @in,  $ind if &__in_group($ind->unique_id(), \@ingroups);
        push @out, $ind if &__in_group($ind->unique_id(), \@outgroups);
        push @ex,  $ind if (scalar @exgroups) && &__in_group($ind->unique_id(), \@exgroups);
    }

    $in_group->add_Individual(@in); #print Dumper($in_group); exit;
    $out_group->add_Individual(@out);

    for my $name ($in_group->get_marker_names) {
        my $in_marker = $in_group->get_Marker($name);
	my @in_alleles = $in_marker->get_Alleles(); #print Dumper(\@in_alleles);
	next if @in_alleles <= 1 || &__is_gap(\@in_alleles); # consider only polymorphic sites among ingroups
	foreach my $ind ($in_group->get_Individuals) {
	    foreach my $geno ($ind->get_Genotypes(-marker => $name)) {
		say join "\t", ("ingroup", $name, $geno->individual_id, $geno->get_Alleles);
	    }
	}

	foreach my $ind ($out_group->get_Individuals) {
	    foreach my $geno ($ind->get_Genotypes(-marker => $name)) {
		say join "\t", ("outgroup", $name, $geno->individual_id, $geno->get_Alleles);
	    }
	}

#	my $out_marker = $out_group->get_Marker($name);
#	my @out_alleles = $out_marker->get_Alleles();
#	print "Marker ", $name, " is a ";
#	if (@out_alleles > 1) {
#	    print "recomb";
#	} else {
#	    print "mut";
#	}
#	print "\n";
#    }
#    print "\n";
    }
}

sub _mk_counts {
    die "Error: ingroup and outgroup options required when using MK test.\n"
        unless ($ingroup && $outgroup);

    my $in_group  = Bio::PopGen::Population->new();
    my $out_group = Bio::PopGen::Population->new();
    my (@out, @in);
    for my $ind ($pop->get_Individuals) {
        push @in,  $ind if ($ind->unique_id =~ /^$ingroup/);
        push @out, $ind if ($ind->unique_id =~ /^$outgroup/);
    }

    my @in_shuffled  = shuffle @in;
    my @out_shuffled = shuffle @out;
    my $size         = _best_sample_size(@in_shuffled);    # ingroup size
    my @in_sample = sample(-set => \@in_shuffled, -sample_size => $size);
    $size = _best_sample_size(@out_shuffled);              # outgroup size

    my @out_sample = sample(-set => \@out_shuffled, -sample_size => $size);

    $in_group->add_Individual(@in_sample);
    $out_group->add_Individual(@out_sample);

    my $mk1 = $stat_obj->mcdonald_kreitman($in_group, $out_group);

    #    my $mk2 = $stat_obj->mcdonald_kreitman($out_group, $in_group);
    say join "\t",
        ($mk1->{poly_N}, $mk1->{fixed_N}, $mk1->{poly_S}, $mk1->{fixed_S});
}

sub _get_Dn_Ds {
    my ($pop1_arr, $Dn_arr, $Ds_arr, $pop2_arr) = @_;

    my $seq1 = $pop1_arr->[ int rand(scalar @$pop1_arr) ];

    # If a second population was given, use that for the second sequence.
    my $seq2
        = ($pop2_arr)
        ? $pop2_arr->[ int rand(scalar @$pop2_arr) ]
        : $pop1_arr->[ int rand(scalar @$pop1_arr) ];

    my $results = $dna_stats->calc_KaKs_pair($aln, $seq1->display_id,
        $seq2->display_id);
    push @$Dn_arr, $results->[0]{D_n};
    push @$Ds_arr, $results->[0]{D_s};
}

sub _sim_mk {
    die "Must specify groups prefix when using simmk"
        unless ($ingroup && $outgroup);

    $sample_size = 100
        unless ($sample_size);

    # Split alignment into two groups based on prefix
    my (@popA, @popB);
    foreach my $seq ($aln->each_seq) {
        if   ($seq->display_id =~ /^$ingroup/) { push @popA, $seq }
        else                                     { push @popB, $seq }
    }

    my (@pa_A, @ps_A, @pa_B, @ps_B, @ka_AB, @ks_AB);

    for (my $i = 1; $i <= $sample_size; $i++) {
        _get_Dn_Ds(\@popA, \@pa_A, \@ps_A);

        _get_Dn_Ds(\@popB, \@pa_B, \@ps_B);

        _get_Dn_Ds(\@popA, \@ka_AB, \@ks_AB, \@popB);
    }

    my @nonsyn_means = (mean(@pa_A), mean(@pa_B), mean(@ka_AB));
    my @syn_means    = (mean(@ps_A), mean(@ps_B), mean(@ks_AB));

    my (@nonsyn_vars, @syn_vars);
    for (0 .. 2) {
        push @nonsyn_vars, variance($nonsyn_means[$_]->query_vector);
        push @syn_vars,    variance($syn_means[$_]->query_vector);
    }

    # Remember, - is left-associative, so this means: = (a - b) - c
    my $ka_AB = $nonsyn_means[2] - $nonsyn_means[0] - $nonsyn_means[1];
    my $ks_AB = $syn_means[2] - $syn_means[0] - $syn_means[1];

    printf "%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n",
        $nonsyn_means[0] + $nonsyn_means[1],
        sqrt($nonsyn_vars[0] + $nonsyn_vars[1]),
        $syn_means[0] + $syn_means[1],
        sqrt($syn_vars[0] + $syn_vars[1]),
        ($ka_AB > 0) ? $ka_AB : 0,
        sqrt(sum(@nonsyn_vars)),
        ($ks_AB > 0) ? $ks_AB : 0,
        sqrt(sum(@syn_vars));
}

sub _print_distance {
    my $warn_bad_dist_method;
    local $SIG{__WARN__} = sub { $warn_bad_dist_method .= shift };

    my $dist_matrix
        = $dna_stats->distance(-align => $aln, -method => $dist_method);

    die "$warn_bad_dist_method\nQuitting on bad distance method...\n"
        if ($warn_bad_dist_method);

    say $dist_matrix->print_matrix;
}

sub _print_kaks_calc {
    my %valid_calcs = (
        "all-pairs" => "calc_all_KaKs_pairs",
        "pair"      => "calc_KaKs_pair",
        "average"   => "calc_average_KaKs"
   );
    my $calc_type = lc($opts->{"kaks"});

    die "Not a valid argument for kaks: $calc_type. Should be one of: ",
        join(' ', keys %valid_calcs), "\n"
        if !($calc_type ~~ %valid_calcs);

    die "Must specify sequence ids if using \"pair\" argument\n"
        if (($calc_type eq "pair") && !($ingroup && $outgroup));

    my $call     = $valid_calcs{$calc_type};
    my @arg_list = ($aln);

    push @arg_list, ($ingroup, $outgroup)
        if ($calc_type eq "pair");

    if ($calc_type eq "average") {
	my $result3 = $dna_stats->calc_average_KaKs($aln, 100);
	for (sort keys %$result3){
	    next if /Seq/;
#	    printf("%-9s %.4f \n",$_ , $result3->{$_});
	    printf("%.6f\t", $result3->{$_});
	}
	print "\n";
    }

sub _print_diversity {
    printf "%s\t%.4f\n", "Nucleotide diversity =>", $pop_stats->pi($pop);
}

sub _print_num_snps {
    print "Number of segregating sites =>", "\t", $pop_stats->segregating_sites_count($pop), "\n";
}
sub _print_heterozygosity {

    print "Heterozygosity=>\n";

    for my $name ($pop->get_marker_names()) {
	my $marker = $pop->get_Marker($name);
	my @alleles = $marker->get_Alleles();
	my %allele_freqs = $marker->get_Allele_Frequencies();
	push @var_sites, $name;
	printf "\t\t%s\t%.4f\n", $name,  &heterozygosity(\%allele_freqs);
    }

}



##############################################################################################
#              HELPER SUBROUTINES
##############################################################################################


sub heterozygosity {
    my $ref = shift;
    my %freq = %$ref;
    my $hom=0;
    foreach my $nt (keys %freq) {
        $hom += $freq{$nt} ** 2;
    }
    return 1-$hom;
}








=begin
    local $@;
    my $results = eval { $dna_stats->$call(@arg_list) };
    if ($@) {
        die "Encountered $@\n";
    }
    for my $an (@$results) {
        say "comparing " . $an->{'Seq1'} . " and " . $an->{'Seq2'}
            unless $calc_type eq "average";
        for (sort keys %$an) {
            next if /Seq/;
            printf("%-9s %.4f \n", $_, $an->{$_});
        }
        say "\n";
    }
=cut
}

1;

=head1 REQUIRES

Perl 5.010, BioPerl

=head1 SEE ALSO

  perl(1)

=head1 AUTHORS

 Weigang Qiu at genectr.hunter.cuny.edu
 Yözen Hernández yzhernand at gmail dot com

=cut
