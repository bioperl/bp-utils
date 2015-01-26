
=head1 NAME

SeqManipulations - Functions for bioseq

=head1 SYNOPSIS

require B<SeqManipulations>;

=cut

use strict;    # Still on 5.10, so need this for strict
use warnings;
use 5.010;
use Bio::Seq;
use Bio::SeqIO;
use File::Basename;
use Bio::Tools::CodonTable;
use Bio::DB::GenBank;

if ( $ENV{'DEBUG'} ) {
    use Data::Dumper;
}

# Package global variables
my ( $in, $out, $seq, %opts, $filename, $in_format, $out_format );

## For new options, just add an entry into this table with the same key as in
## the GetOpts function in the main program. Make the key be a reference to
## the handler subroutine (defined below), and test that it works.  
my %opt_dispatch = ( 'anonymize' => \&anonymize, 
		     'composition' => \&print_composition, 
		     'delete' => \&filter_seqs, 
#		     'dotplot' => \&draw_dotplot, 
		     'extract' => \&reading_frame_ops, 
		     'leadgaps' => \&count_leading_gaps, 
		     'length' => \&print_lengths, 
		     'linearize' => \&linearize, 
#		     'longest-orf' => \&reading_frame_ops, 
		     'nogaps' => \&remove_gaps, 
		     'numseq' => \&print_seq_count, 
		     'pick' => \&filter_seqs,
		     'prefix' => \&anonymize, 
#		     'rename' => \&rename_id, 
		     'reloop' => \&reloop_at, 
		     'removestop' => \&remove_stop, 
		     'fetch' => \&retrieve_seqs, 
		     'revcom' => \&make_revcom, 
		     'break' => \&shred_seq,
#		     'slidingwindow' => \&sliding_window, 
		     'split' => \&split_seqs, 
		     'subseq' => \&print_subseq, 
		     'translate' => \&reading_frame_ops, 
    );

my %filter_dispatch = (
    'find_by_order'  => \&find_by_order,
    'pick_by_order'  => \&pick_by_order,
    'del_by_order'   => \&del_by_order,
    'find_by_id'     => \&find_by_id,
    'pick_by_id'     => \&pick_by_id,
    'del_by_id'      => \&del_by_id,
    'find_by_re'     => \&find_by_re,
    'pick_by_re'     => \&pick_by_re,
    'del_by_re'      => \&del_by_re,
    'find_by_ambig'  => \&find_by_ambig,
    'pick_by_ambig'  => \&pick_by_ambig,
    'del_by_ambig'   => \&del_by_ambig,
    'find_by_length' => \&find_by_length,
    'pick_by_length' => \&pick_by_length,
    'del_by_length'  => \&del_by_length
);

################################################################################
## Subroutines
################################################################################

## TODO Function documentation!
## TODO Formal testing!

sub initialize {
    my $val = shift;
    %opts = %{$val};

    die "Option 'prefix' requires a value\n"
        if ( ( defined $opts{"prefix"} ) && ( $opts{"prefix"} =~ /^$/ ) );

    $filename = shift @ARGV
        || "STDIN";    # If no more arguments were given on the command line,
                       # assume we're getting input from standard input

    $in_format = $opts{"input"} // 'fasta';

    if ( $filename eq "STDIN" ) {    # We're getting input from STDIN
        $in = Bio::SeqIO->new( -format => $in_format, -fh => \*STDIN );
    }
    else {                           # Filename, or '-', was given
        $in = Bio::SeqIO->new(
            -format => $in_format,
            -file   => "<$filename"
        );
    }

    $out_format = $opts{"output"} // 'fasta';

# A change in SeqIO, commit 0e04486ca4cc2e61fd72, means -fh or -file is required
    $out = Bio::SeqIO->new( -format => $out_format, -fh => \*STDOUT );
}

sub write_out {
    while ( $seq = $in->next_seq() ) {
        $out->write_seq($seq);
    }
}

sub reloop_at {
    my $seq = $in->next_seq; # only the first sequence
    my $break = $opts{"reloop"};
    my $new_seq = Bio::Seq->new(
	-id => $seq->id() . ":relooped_at_" . $break,
	-seq => $seq->subseq($break, $seq->length()) . $seq->subseq(1, $break-1),
	);
    $out->write_seq($new_seq);
}

sub can_handle {
    my $option = shift;
    return defined( $opt_dispatch{$option} );
}

sub handle_opt {
    my $option = shift;

    # This passes option name to all functions
    $opt_dispatch{$option}->($option);
}

sub count_leading_gaps {
    while ( $seq = $in->next_seq() ) {
        my $lead_gap = 0;
        my $see_aa   = 0;                       # status variable
        my @mono     = split //, $seq->seq();
        for ( my $i = 0; $i < $seq->length(); $i++ ) {
            $see_aa = 1 if $mono[$i] ne '-';
            $lead_gap++ if !$see_aa && $mono[$i] eq '-';
        }
        print $seq->id(), "\t", $lead_gap, "\n";
    }
}
## Option handlers go below this line ##

## BEGIN pick/delete filters
sub find_by_order {
    my ( $action, $ct, $currseq, $order_list ) = @_;

    $filter_dispatch{ $action . "_by_order" }->( $ct, $currseq, $order_list );
}

sub pick_by_order {
    my ( $ct, $currseq, $order_list ) = @_;

    $out->write_seq($currseq)
        if ( $order_list->{$ct} );
}

sub del_by_order {
    my ( $ct, $currseq, $order_list ) = @_;

    if ( $order_list->{$ct} ) {
        warn "Deleted sequence: ", $currseq->id(), "\n";
    }
    else {
        $out->write_seq($currseq);
    }
}

sub find_by_id {
    my ( $action, $match, $currseq, $id_list ) = @_;
    my $seq_id = $currseq->id();

    $filter_dispatch{ $action . "_by_id" }
        ->( $match, $currseq, $id_list, $seq_id );
}

sub pick_by_id {
    my ( $match, $currseq, $id_list, $seq_id ) = @_;

    if ( $id_list->{$seq_id} ) {
        $id_list->{$seq_id}++;
        die "Multiple matches ("
            . $id_list->{$seq_id} - 1
            . ") for $match found\n"
            if $id_list->{$seq_id} > 2;

        $out->write_seq($currseq);
    }
}

sub del_by_id {
    my ( $match, $currseq, $id_list, $seq_id ) = @_;

    if ( $id_list->{$seq_id} ) {
        $id_list->{$seq_id}++;
        warn "Deleted sequence: ", $currseq->id(), "\n";
    }
    else {
        $out->write_seq($currseq);
    }
}

sub find_by_re {
    my ( $action, $currseq, $value ) = @_;
    my $regex  = qr/$value/;
    my $seq_id = $currseq->id();

    $filter_dispatch{ $action . "_by_re" }->( $currseq, $regex, $seq_id );
}

sub pick_by_re {
    my ( $currseq, $regex, $seq_id ) = @_;

    $out->write_seq($currseq)
        if ( $seq_id =~ /$regex/ );
}

sub del_by_re {
    my ( $currseq, $regex, $seq_id ) = @_;

    if ( $seq_id =~ /$regex/ ) {
        warn "Deleted sequence: $seq_id\n";
    }
    else {
        $out->write_seq($currseq);
    }
}

sub find_by_length {
    my ( $action, $currseq, $value ) = @_;

    $filter_dispatch{ $action . "_by_length" }->( $currseq, $value );
}

sub pick_by_length {
    my ( $currseq, $value ) = @_;

    $out->write_seq($currseq)
        if ( $currseq->length() <= $value );
}

sub del_by_length {
    my ( $currseq, $value ) = @_;

    if ( $currseq->length() <= $value ) {
        warn "Deleted sequence: ", $currseq->id(), " length: ",
            $currseq->length(), "\n";
    }
    else {
        $out->write_seq($currseq);
    }
}

# TODO This needs better documentation
sub find_by_ambig {
    my ( $action, $currseq, $cutoff ) = @_;
    my $string        = $currseq->seq();
    my $ct            = ( $string =~ s/n/n/gi );
    my $percent_ambig = $ct / $currseq->length();

    $filter_dispatch{ "$action" . "_by_ambig" }
        ->( $currseq, $cutoff, $ct, $percent_ambig );
}

# TODO Probably better to change behavior when 'picking'?
sub pick_by_ambig {
    my ( $currseq, $cutoff, $ct, $percent_ambig ) = @_;

    $out->write_seq($currseq)
        if ( $percent_ambig > $cutoff );
}

sub del_by_ambig {
    my ( $currseq, $cutoff, $ct, $percent_ambig ) = @_;

    if ( $percent_ambig > $cutoff ) {
        warn "Deleted sequence: ", $currseq->id(), " number of N: ", $ct,
            "\n";
    }
    else {
        $out->write_seq($currseq);
    }
}
## END pick/delete filters

sub parse_orders {
    my @selected = @{ shift() };

    my @orders;

    # Parse if $value contains ranges: allows mixing ranges and lists
    foreach my $val (@selected) {
        if ( $val =~ /^(\d+)-(\d+)$/ ) {    # A numerical range
            my ( $first, $last ) = ( $1, $2 );
            die "Invalid seq range: $first, $last\n"
                unless $last > $first;
            push @orders, ( $first .. $last );
        }
        else {
            push @orders, $val;             # Single value
        }
    }

    return map { $_ => 1 } @orders;
}

# This sub calls all the del/pic subs above. Any option to filter input
# sequences by some criterion goes through here, and the appropriate filter
# subroutine is called.
sub filter_seqs {
    my $action = shift;
    my $match  = $opts{$action};

# matching to stop at 1st ':' so that ids using ':' as field delimiters are handled properly
    $match =~ /^([^:]+):(\S+)$/
        || die
        "Bad search format. Expecting a pattern of the form: tag:value.\n";

    my ( $tag, $value ) = ( $1, $2 );
    my @selected = split( /,/, $value );
    my $callsub = "find_by_" . "$tag";

    die "Bad tag or function not implemented. Tag was: $tag\n"
        if ( !defined( $filter_dispatch{$callsub} ) );

    if ( $tag eq 'order' ) {
        my $ct = 0;

        # Parse selected orders and create a hash
        my %order_list = parse_orders( \@selected );

        while ( my $currseq = $in->next_seq ) {
            $ct++;
            $filter_dispatch{$callsub}
                ->( $action, $ct, $currseq, \%order_list );
        }

        foreach my $order ( keys %order_list ) {
            print STDERR "No matches found for order number $order\n"
                if $order > $ct;
        }
    }
    elsif ( $tag eq 'id' ) {
        my %id_list
            = map { $_ => 1 } @selected;    # create a hash from @selected

        while ( my $currseq = $in->next_seq ) {
            $filter_dispatch{$callsub}
                ->( $action, $match, $currseq, \%id_list );
        }

        foreach my $id ( keys %id_list ) {
            warn "No matches found for '$id'\n"
                if $id_list{$id} == 1;
        }
    }
    else {
        while ( my $currseq = $in->next_seq ) {
            $filter_dispatch{$callsub}->( $action, $currseq, $value );
        }
    }
}

sub print_lengths {
    while ( $seq = $in->next_seq() ) {
        print $seq->id(),     "\t";
        print $seq->length(), "\n";
    }
}

sub print_seq_count {
    my $count;
    while ( $seq = $in->next_seq() ) {
        $count++;
    }
    print $count, "\n";
}

sub print_subseq {
    while ( $seq = $in->next_seq() ) {
        my $id = $seq->id();
        my ( $start, $end ) = split /\s*,\s*/, $opts{"subseq"};
        die "end out of bound: $id\n" if $end > $seq->length();
        my $new = Bio::Seq->new(
            -id  => $seq->id() . ":$start-$end",
            -seq => $seq->subseq( $start, $end )
        );
        $out->write_seq($new);
    }
}

sub remove_gaps {    # remove gaps
    while ( $seq = $in->next_seq() ) {
        my $string = $seq->seq();
        $string =~ s/-//g;
        my $new_seq = Bio::Seq->new( -id => $seq->id(), -seq => $string );

        #         print ">", $seq->id(), "\n";
        #         print $string, "\n";
        $out->write_seq($new_seq);
    }
}

sub sliding_window {    #
    my $win_size = $opts{"slidingwindow"} ? $opts{"slidingwindow"} : 1;
    while ( $seq = $in->next_seq() ) {
        my $string = $seq->seq();
        for ( my $i = 1; $i <= $seq->length() - $win_size + 1; $i++ ) {
            print $seq->subseq( $i, $i + $win_size - 1 ), "\n";
        }
    }
}

sub linearize {
    while ( $seq = $in->next_seq() ) {
        print $seq->id(),  "\t";
        print $seq->seq(), "\n";
    }
}

sub make_sed_file {
    my $filename = shift @_;
    my (%serial_names) = @_;

    $filename = "STDOUT" if $filename eq '-';

    my $sedfile = basename($filename) . ".sed";
    open( SEDOUT, ">", $sedfile ) or die $!;

    print SEDOUT "# usage: sed -f $filename.sed <anonymized file>\n";

    foreach my $serial ( keys %serial_names ) {
        my $real_name = $serial_names{$serial};
        my $sed_cmd   = "s/$serial/" . $real_name . "/g;\n";
        print SEDOUT $sed_cmd;
    }
    close SEDOUT;

    print STDERR
        "\nCreated $filename.sed\tusage: sed -f $filename.sed <anonymized file>\n\n";
}

sub anonymize {
    my $char_len = $opts{"anonymize"} // die
        "Tried to use option 'preifx' without using option 'anonymize'. Exiting...\n";
    my $prefix = ( defined( $opts{"prefix"} ) ) ? $opts{"prefix"} : "S";

    pod2usage(1) if ( $char_len < 1 );

    my $ct = 1;
    my %serial_name;
    my $length_warn = 0;
    while ( $seq = $in->next_seq() ) {
        my $serial
            = $prefix . sprintf "%0" . ( $char_len - length($prefix) ) . "s",
            $ct;
        $length_warn = 1
            if ( length($serial) > $char_len );
        $serial_name{$serial} = $seq->id();
        $seq->id($serial);
        $out->write_seq($seq);
        $ct++;
    }

    make_sed_file( $filename, %serial_name );
    warn "Anonymization map:\n";
    while ( my ( $k, $v ) = each %serial_name ) {
        warn "$k => $v\n";
    }

    warn
        "WARNING: Anonymized ID length exceeded requested length: try a different length or prefix.\n"
        if $length_warn;
}

sub make_revcom {    # reverse-complement a sequence
    while ( $seq = $in->next_seq() ) {
        my $new = Bio::Seq->new(
            -id  => $seq->id() . ":revcom",
            -seq => $seq->revcom()->seq()
        );
        $out->write_seq($new);
    }
}

sub remove_stop {
    my $myCodonTable = Bio::Tools::CodonTable->new( -id => 11 );
    while ( $seq = $in->next_seq() ) {
        my $newstr = "";
        for ( my $i = 1; $i <= $seq->length() / 3; $i++ ) {
            my $codon
                = $seq->subseq( 3 * ( $i - 1 ) + 1, 3 * ( $i - 1 ) + 3 );
            if ( $myCodonTable->is_ter_codon($codon) ) {
                warn "Found and removed stop codon\n";
                next;
            }
            $newstr .= $codon;
        }
        my $new = Bio::Seq->new(
            -id  => $seq->id(),
            -seq => $newstr
        );
        $out->write_seq($new);
    }
}

# To do: add fetch by gi
sub retrieve_seqs {
    my $gb  = Bio::DB::GenBank->new();
    my $seq = $gb->get_Seq_by_acc($opts{'fetch'}); # Retrieve sequence with Accession Number
    $out->write_seq($seq);
}

sub print_composition {
    while ( $seq = $in->next_seq() ) {
        print $seq->id(), "\n";
        my $string = $seq->seq();
        my $ct     = length($string);
        my @chars  = split //, $string;
        my %seen;

        foreach (@chars) {
	  next unless /[a-zA-Z]/;
            # If character hasn't been seen, get its count and print that.
	  if ( !$seen{$_}++ ) {   # This ensures the char gets into the hash
	    my $count = ( $string =~ s/$_/$_/g );
	    printf "\t'$_' => '%6d\t%.2f%s'\n", $count,
	      $count * 100 / $ct,
		' %';
	  }
        }
	
        print Dumper( \%seen )
	  if ( $ENV{'DEBUG'} );
        print "\n";
      }
  }


sub shred_seq {
    while ( $seq = $in->next_seq() ) {
        my $newid = $seq->id();
        $newid =~ s/[\s\|]/_/g;
        print $newid, "\n";
        my $newout = Bio::SeqIO->new(
            -format => $out_format,
            -file   => ">" . $newid . ".fas"
        );
        $newout->write_seq($seq);
    }
    exit;
}

sub print_gb_gene_feats {
    $seq = $in->next_seq();
    foreach my $feat ( $seq->get_SeqFeatures() ) {
        if ( $feat->primary_tag eq 'gene' ) {
            print join "\t",
                ( $feat->gff_string, $feat->start, $feat->end,
                $feat->strand );
            print "\n";
        }
    }
}

1;

=begin legacy codes, rarely used

sub update_longest_reading_frame {
    my $seqobj  = shift;
    my $longest = shift;

    foreach my $fm ( 1, 2, 3 ) {

        #      print STDERR "checking frame $fm ...\n";
        my $new_seqobj = Bio::Seq->new(
            -id  => $seqobj->id() . "|$fm",
            -seq => $seqobj->subseq( $fm, $seqobj->length() )
        );    # chop seq to frame first
        my $pep_string = $new_seqobj->translate( undef, undef, 0 )->seq();
        my $three_prime = $new_seqobj->length();

        my $start = 1;
        my @aas = split '', $pep_string;
        for ( my $i = 0; $i <= $#aas; $i++ ) {
            if ( $aas[$i] eq '*' || $i == $#aas )
            {    # hit a stop codon or end of sequence
                if ( $i - $start + 2 > $longest->{aa_length} ) {
                    $longest->{aa_start}  = $start;
                    $longest->{aa_end}    = $i + 1;
                    $longest->{aa_length} = $i - $start + 2;
                    $longest->{nt_start}  = 3 * ( $start - 1 ) + 1;
                    my $end = 3 * $i + 3;
                    $end
                        = ( $end > $three_prime )
                        ? $three_prime
                        : $end;    # guranteed not to go beyond 3'
                    $longest->{nt_end} = $end;
                    $longest->{frame}  = $fm;
                    $longest->{nt_seq}
                        = $new_seqobj->subseq( 3 * ( $start - 1 ) + 1, $end );

#         print ">longer_orf_$start", "_$fm\n", $new_seqobj->subseq(3*($start-1)+1, $end), "\n";
                }
                $start = $i + 2;
            }
            else {                 # not a stop codon
                next;
            }
        }
    }

    foreach my $fm ( 1, 2, 3 ) {    # reverse complement

        #      print STDERR "checking frame -$fm ...\n";
        my $new_seqobj = Bio::Seq->new(
            -id  => $seqobj->id() . "|$fm",
            -seq => $seqobj->revcom()->subseq( $fm, $seqobj->length() )
        );                          # chop seq to frame first
        my $pep_string = $new_seqobj->translate( undef, undef, 0 )->seq();
        my $three_prime = $new_seqobj->length();

        my $start = 1;
        my @aas = split '', $pep_string;
        for ( my $i = 0; $i <= $#aas; $i++ ) {
            if ( $aas[$i] eq '*' || $i == $#aas )
            {                       # hit a stop codon or end of sequence
                if ( $i - $start + 2 > $longest->{aa_length} ) {
                    $longest->{aa_start}  = $start;
                    $longest->{aa_end}    = $i + 1;
                    $longest->{aa_length} = $i - $start + 2;
                    $longest->{nt_start}  = 3 * ( $start - 1 ) + 1;

                    my $end = 3 * $i + 3;
                    $end
                        = ( $end > $three_prime )
                        ? $three_prime
                        : $end;     # guranteed not to go beyond 3'
                    $longest->{nt_end} = $end;
                    $longest->{frame}  = $fm;
                    $longest->{nt_seq}
                        = $new_seqobj->subseq( 3 * ( $start - 1 ) + 1, $end );

#         print ">longer_orf_$start", "_$fm\n", $new_seqobj->subseq(3*($start-1)+1, $end), "\n";
                }
                $start = $i + 2;
            }
            else {                  # not a stop codon
                next;
            }
        }
    }
    warn "no start codon:", $seqobj->id(), "\n"
        unless substr( $longest->{nt_seq}, 0, 3 ) =~ /atg/i;
    return $longest;
}

sub reading_frame_ops {
    my $frame = $opts{"translate"};
    while ( $seq = $in->next_seq() ) {
        my $inframe;

        my $ct = 0;
        my $trans0 = $seq->translate( -frame => 0 );
        if ( $opts{"extract"} && $trans0->seq =~ /^M[^\*]+\**$/ ) {
            $inframe = $seq->seq();
            $ct++;
        }

        my $trans1 = $seq->translate( -frame => 1 );
        if ( $opts{"extract"} && $trans1->seq =~ /^M[^\*]+\**$/ ) {
            $inframe = $seq->subseq( 2, $seq->length() );
            $ct++;
        }

        my $trans2 = $seq->translate( -frame => 2 );
        if ( $opts{"extract"} && $trans2->seq =~ /^M[^\*]+\**$/ ) {
            $inframe = $seq->subseq( 3, $seq->length() );
            $ct++;
        }
        my $rev = $seq->revcom();
        my $rev0 = $rev->translate( -frame => 0 );
        if ( $opts{"extract"} && $rev0->seq =~ /^M[^\*]+\**$/ ) {
            $inframe = $rev->seq();
            $ct++;
        }
        my $rev1 = $rev->translate( -frame => 1 );
        if ( $opts{"extract"} && $rev1->seq =~ /^M[^\*]+\**$/ ) {
            $inframe = $rev->subseq( 2, $rev->length() );
            $ct++;
        }
        my $rev2 = $rev->translate( -frame => 2 );
        if ( $opts{"extract"} && $rev2->seq =~ /^M[^\*]+\**$/ ) {
            $inframe = $rev->subseq( 3, $rev->length() );
            $ct++;
        }
        my $id = $seq->display_id();

        if ( $opts{"longest-orf"} )
        {    # find and return the longest ORF within a single seq
            my $longest_reading_frame = {
                'aa_start'  => 1,
                'aa_end'    => 1,
                'aa_length' => 1,
                'nt_start'  => 1,
                'nt_end'    => 1,
                'nt_seq'    => undef,
                'frame'     => undef,
            };

            my $longest_orf_found = update_longest_reading_frame( $seq,
                $longest_reading_frame );
            print ">$id|f", $longest_orf_found->{frame}, "|longest-orf\n",
                $longest_orf_found->{nt_seq}, "\n";
        }

        if ( $opts{"extract"} ) {
            if ( $ct > 1 ) {
                warn "$id has more than one reading frame: $ct. Skipped\n";
            }
            elsif ( $ct == 1 ) {
                print ">$id|inframe\n", $inframe, "\n";
            }
            else {
                warn "$id has no open reading frame: $ct. Skipped\n";
            }
        }
        elsif ( $opts{"translate"} ) {
            print ">", $id, "\n", $trans0->seq, "\n" if $frame == 1;
            print ">$id|+1\n", $trans0->seq, "\n", ">$id|+2\n",
                $trans1->seq(),
                "\n", ">$id|+3\n", $trans2->seq(), "\n", ">$id|-1\n",
                $rev0->seq,
                "\n", ">$id|-2\n", $rev1->seq(), "\n", ">$id\|-3\n",
                $rev2->seq(), "\n\n"
                if $frame == 6;
            print ">$id|+1\n", $trans0->seq, "\n", ">$id|+2\n",
                $trans1->seq(), "\n", ">$id|+3\n", $trans2->seq(), "\n\n"
                if $frame == 3;
        }
        else { next; }
    }
}

sub split_seqs {
    my $split_at   = $opts{"split"};
    my $out_prefix = $filename . "_split_";
    my $fcount     = 1;
    my $scount     = 0;
    my $out_file   = $out_prefix . $fcount . ".$out_format";
    my $newout     = Bio::SeqIO->new(
        -format => $out_format,
        -file   => ">" . $out_file,
    );
    while ( $seq = $in->next_seq() ) {
        $newout->write_seq($seq);
        $scount++;

        if ( ( $scount % $split_at ) == 0 ) {
            $fcount++;
            $out_file = $out_prefix . $fcount . ".$out_format";
            $newout = Bio::SeqIO->new(
                -format => $out_format,
                -file   => ">" . $out_file,
            );
        }
    }

    if ( (-s $out_file) == 0 ) {
        unlink $out_file;
    }
}

sub draw_dotplot {

    my ($id1, $id2, $window) = split(/,/ , $opts{'dotplot'}); #options are entered using comma (,) as delimitor 
    my $winsize = $window ? $window : 10; #default windowsize is 10
    my (@seq1, @seq2);

    #Get the ID and corresponding sequence from fasta input
    while (my $seq = $in->next_seq()) {
	if($seq->id() eq $id1){
	    @seq1 = split(//, $seq->seq());
	}
	if($seq->id() eq $id2){
	    @seq2 = split(//, $seq->seq());
	}
    }

    #counters $a counts the rows while $b counts the columns
    my $a = 0;
    my $b = 0;

    print "\t"; #padding for top sequence
    print "$_\t" foreach @seq1; #print the horizontal axis
    print "\n"; #begin the plot space
  
    for(my $o = 0; $o<=$#seq2; $o++){ 
	print $seq2[$o], "\t";    #print the vertical axis

	if ($b <= ($#seq2 - $winsize)){   
	    my $c_win = join("", @seq2[$b..$winsize+$b-1]);
	    for(my $i=0; $i<= $#seq1; $i++){
		if ($a <= ($#seq1 - $winsize)){
		    my $r_win = join("", @seq1[$a..$winsize+$a-1]);
          
		    ($r_win eq $c_win) ? (print "*\t") : (print "\t");  #if the column window (c_win) equals the row window (r_win) then print a * other wise place a tab
		    $a++; #go through each row windows
		}
	    }
	    $b++; #go to next column window (c_win)
	    $a=0; #reset row counter to begin checks again
	}
	print "\n";
    }
}

sub rename_id {
    my $ref = $opts{'rename'};
    open (REF, $ref) or die "Cannot open $ref!\n";
    open (FASTA, $filename) or die "Cannot open $filename!\n";
    my %change;
    while (my $line = <REF>)
    {
	chomp ($line);
	my ($from, $to) = split(/[\s|\t]+/, $line);
	$change{$from} = $to;
    }
    while (my $line = <FASTA>)
    {
	chomp ($line);
	if ($line =~ m/^>(\S+)$/)
	{
	    my $check = $change{$1};
	    if (defined ($check))
	    {
		$line =~ s/$1/$check/g;
	    }
	}
	print $line, "\n";
    }
}

=cut

