use warnings; use strict;
use Test::More;
use File::Basename qw(dirname basename); use File::Spec;

# Funky terminals like xterm on cygwin can mess up output comparison.
$ENV{'TERM'}='dumb';

package Helper;
use English qw( -no_match_vars ) ;
use Config;
use File::Basename qw(dirname basename); use File::Spec;
require Exporter;
our (@ISA, @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(run_bio_program);

my $debug = $^W;

# Runs bio program in a subshell. 0 is returned if everything went okay.
# nonzero if something went wrong.
sub run_bio_program($$$$;$)
{
    my ($bio_program, $data_filename, $run_opts, $check_filename,
	$other_opts) = @_;
    $other_opts = {} unless defined $other_opts;
    $other_opts->{do_test} = 1 unless exists $other_opts->{do_test};
    Test::More::note( "running $bio_program $run_opts $data_filename" );
    my $dirname = dirname(__FILE__);
    my $full_data_filename = File::Spec->catfile($dirname, '..', 'test-files',
						 $data_filename);

    my $full_check_filename = File::Spec->catfile($dirname, 'check-data',
						  $check_filename);
    my $full_bio_progname = File::Spec->catfile($dirname, '..', $bio_program);

    my $ext_file = sub {
        my ($ext) = @_;
        my $new_fn = $full_check_filename;
        $new_fn =~ s/\.right\z/.$ext/;
        return $new_fn;
    };

    my $err_filename = $ext_file->('err');

    my $cmd = "$EXECUTABLE_NAME $full_bio_progname $run_opts $full_data_filename " .
	"2>$err_filename";
    print $cmd, "\n"  if $debug;
    my $output = `$cmd`;
    print "$output\n" if $debug;
    my $rc = $CHILD_ERROR >> 8;
    my $test_rc = $other_opts->{exitcode} || 0;
    if ($other_opts->{do_test}) {
	Test::More::is($rc, $test_rc, "command ${bio_program} executed giving exit code $test_rc");
    }
    return $rc if $rc;

    open(RIGHT_FH, "<$full_check_filename") ||
	die "Cannot open $full_check_filename for reading - $OS_ERROR";
    undef $INPUT_RECORD_SEPARATOR;
    my $right_string = <RIGHT_FH>;
    ($output, $right_string) = $other_opts->{filter}->($output, $right_string)
	if $other_opts->{filter};
    my $got_filename;
    $got_filename = $ext_file->('got');
    # TODO : Perhaps make sure we optionally use eq_or_diff from
    # Test::Differences here.
    my $equal_output = $right_string eq $output;
    Test::More::ok($right_string eq $output, 'Output comparison')
	if $other_opts->{do_test};
    if ($equal_output) {
        unlink $got_filename;
	return 0;
    } else {
        open (GOT_FH, '>', $got_filename)
            or die "Cannot open '$got_filename' for writing - $OS_ERROR";
        print GOT_FH $output;
        close GOT_FH;
        Test::More::diag("Compare $got_filename with $check_filename:");
	# FIXME use a better diff test.
	if ($OSNAME eq 'MSWin32') {
	    # Windows doesn't do diff.
	    diag("Got:\n", $output, "Need:\n", $right_string);
	} else {
	    my $output = `diff -au $check_filename $got_filename 2>&1`;
	    my $rc = $? >> 8;
	    # GNU diff returns 0 if files are equal, 1 if different and 2
	    # if something went wrong. We also should take care of the
	    # case where diff isn't installed. So although we expect a 1
	    # for GNU diff, we'll also take accept 0, but any other return
	    # code means some sort of failure.
	    $output = `diff $check_filename $got_filename 2>&1`
		if ($rc > 1) || ($rc < 0) ;
	    Test::More::diag($output);
	    return 1;
	}
    }
}

# Demo program
unless(caller) {
    run_bio_program('bioaln', 'test-bioaln.cds', '-a', 'opt-a.right');
    Test::More::done_testing();
}
1;
