#***************************************************************************
#                                  _   _ ____  _
#  Project                     ___| | | |  _ \| |
#                             / __| | | | |_) | |
#                            | (__| |_| |  _ <| |___
#                             \___|\___/|_| \_\_____|
#
# Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.
#
# This software is licensed as described in the file COPYING, which
# you should have received as part of this distribution. The terms
# are also available at https://curl.se/docs/copyright.html.
#
# You may opt to use, copy, modify, merge, publish, distribute and/or sell
# copies of the Software, and permit persons to whom the Software is
# furnished to do so, under the terms of the COPYING file.
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
# KIND, either express or implied.
#
# SPDX-License-Identifier: curl
#
###########################################################################

# This module contains entry points to run a single test

package runner;

use strict;
use warnings;

BEGIN {
    use base qw(Exporter);

    our @EXPORT = qw(
        checktestcmd
        prepro
        restore_test_env
        runner_clearlocks
        runner_stopservers
        runner_test_preprocess
        runner_test_run
        setlogfunc
        $DBGCURL
        $gdb
        $gdbthis
        $gdbxwin
        $shallow
        $tortalloc
        $valgrind_logfile
        $valgrind_tool
    );

    # these are for debugging only
    our @EXPORT_OK = qw(
        readtestkeywords
        singletest_preprocess
    );
}

use pathhelp qw(
    exe_ext
    );
use processhelp qw(
    portable_sleep
    );
use servers qw(
    checkcmd
    clearlocks
    serverfortest
    stopserver
    stopservers
    subvariables
    );
use getpart;
use globalconfig;
use testutil qw(
    clearlogs
    logmsg
    runclient
    subbase64
    subnewlines
    );


#######################################################################
# Global variables set elsewhere but used only by this package
our $DBGCURL=$CURL; #"../src/.libs/curl";  # alternative for debugging
our $valgrind_logfile="--log-file";  # the option name for valgrind >=3
our $valgrind_tool="--tool=memcheck";
our $gdb = checktestcmd("gdb");
our $gdbthis;      # run test case with gdb debugger
our $gdbxwin;      # use windowed gdb when using gdb

# torture test variables
our $shallow;
our $tortalloc;

# local variables
my %oldenv;       # environment variables before test is started
my $UNITDIR="./unit";
my $CURLLOG="$LOGDIR/commands.log"; # all command lines run
my $SERVERLOGS_LOCK="$LOGDIR/serverlogs.lock"; # server logs advisor read lock
my $defserverlogslocktimeout = 2; # timeout to await server logs lock removal
my $defpostcommanddelay = 0; # delay between command and postcheck sections


#######################################################################
# Check for a command in the PATH of the machine running curl.
#
sub checktestcmd {
    my ($cmd)=@_;
    my @testpaths=("$LIBDIR/.libs", "$LIBDIR");
    return checkcmd($cmd, @testpaths);
}

# See if Valgrind should actually be used
sub use_valgrind {
    if($valgrind) {
        my @valgrindoption = getpart("verify", "valgrind");
        if((!@valgrindoption) || ($valgrindoption[0] !~ /disable/)) {
            return 1;
        }
    }
    return 0;
}

# Massage the command result code into a useful form
sub normalize_cmdres {
    my $cmdres = $_[0];
    my $signal_num  = $cmdres & 127;
    my $dumped_core = $cmdres & 128;

    if(!$anyway && ($signal_num || $dumped_core)) {
        $cmdres = 1000;
    }
    else {
        $cmdres >>= 8;
        $cmdres = (2000 + $signal_num) if($signal_num && !$cmdres);
    }
    return ($cmdres, $dumped_core);
}

# 'prepro' processes the input array and replaces %-variables in the array
# etc. Returns the processed version of the array
sub prepro {
    my $testnum = shift;
    my (@entiretest) = @_;
    my $show = 1;
    my @out;
    my $data_crlf;
    for my $s (@entiretest) {
        my $f = $s;
        if($s =~ /^ *%if (.*)/) {
            my $cond = $1;
            my $rev = 0;

            if($cond =~ /^!(.*)/) {
                $cond = $1;
                $rev = 1;
            }
            $rev ^= $feature{$cond} ? 1 : 0;
            $show = $rev;
            next;
        }
        elsif($s =~ /^ *%else/) {
            $show ^= 1;
            next;
        }
        elsif($s =~ /^ *%endif/) {
            $show = 1;
            next;
        }
        if($show) {
            # The processor does CRLF replacements in the <data*> sections if
            # necessary since those parts might be read by separate servers.
            if($s =~ /^ *<data(.*)\>/) {
                if($1 =~ /crlf="yes"/ ||
                   ($feature{"hyper"} && ($keywords{"HTTP"} || $keywords{"HTTPS"}))) {
                    $data_crlf = 1;
                }
            }
            elsif(($s =~ /^ *<\/data/) && $data_crlf) {
                $data_crlf = 0;
            }
            subvariables(\$s, $testnum, "%");
            subbase64(\$s);
            subnewlines(0, \$s) if($data_crlf);
            push @out, $s;
        }
    }
    return @out;
}


#######################################################################
# Load test keywords into %keywords hash
#
sub readtestkeywords {
    my @info_keywords = getpart("info", "keywords");

    # Clear the list of keywords from the last test
    %keywords = ();
    for my $k (@info_keywords) {
        chomp $k;
        $keywords{$k} = 1;
    }
}


#######################################################################
# Memory allocation test and failure torture testing.
#
sub torture {
    my ($testcmd, $testnum, $gdbline) = @_;

    # remove memdump first to be sure we get a new nice and clean one
    unlink($memdump);

    # First get URL from test server, ignore the output/result
    runclient($testcmd);

    logmsg " CMD: $testcmd\n" if($verbose);

    # memanalyze -v is our friend, get the number of allocations made
    my $count=0;
    my @out = `$memanalyze -v $memdump`;
    for(@out) {
        if(/^Operations: (\d+)/) {
            $count = $1;
            last;
        }
    }
    if(!$count) {
        logmsg " found no functions to make fail\n";
        return 0;
    }

    my @ttests = (1 .. $count);
    if($shallow && ($shallow < $count)) {
        my $discard = scalar(@ttests) - $shallow;
        my $percent = sprintf("%.2f%%", $shallow * 100 / scalar(@ttests));
        logmsg " $count functions found, but only fail $shallow ($percent)\n";
        while($discard) {
            my $rm;
            do {
                # find a test to discard
                $rm = rand(scalar(@ttests));
            } while(!$ttests[$rm]);
            $ttests[$rm] = undef;
            $discard--;
        }
    }
    else {
        logmsg " $count functions to make fail\n";
    }

    for (@ttests) {
        my $limit = $_;
        my $fail;
        my $dumped_core;

        if(!defined($limit)) {
            # --shallow can undefine them
            next;
        }
        if($tortalloc && ($tortalloc != $limit)) {
            next;
        }

        if($verbose) {
            my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
                localtime(time());
            my $now = sprintf("%02d:%02d:%02d ", $hour, $min, $sec);
            logmsg "Fail function no: $limit at $now\r";
        }

        # make the memory allocation function number $limit return failure
        $ENV{'CURL_MEMLIMIT'} = $limit;

        # remove memdump first to be sure we get a new nice and clean one
        unlink($memdump);

        my $cmd = $testcmd;
        if($valgrind && !$gdbthis) {
            my @valgrindoption = getpart("verify", "valgrind");
            if((!@valgrindoption) || ($valgrindoption[0] !~ /disable/)) {
                my $valgrindcmd = "$valgrind ";
                $valgrindcmd .= "$valgrind_tool " if($valgrind_tool);
                $valgrindcmd .= "--quiet --leak-check=yes ";
                $valgrindcmd .= "--suppressions=$srcdir/valgrind.supp ";
                # $valgrindcmd .= "--gen-suppressions=all ";
                $valgrindcmd .= "--num-callers=16 ";
                $valgrindcmd .= "${valgrind_logfile}=$LOGDIR/valgrind$testnum";
                $cmd = "$valgrindcmd $testcmd";
            }
        }
        logmsg "*** Function number $limit is now set to fail ***\n" if($gdbthis);

        my $ret = 0;
        if($gdbthis) {
            runclient($gdbline);
        }
        else {
            $ret = runclient($cmd);
        }
        #logmsg "$_ Returned " . ($ret >> 8) . "\n";

        # Now clear the variable again
        delete $ENV{'CURL_MEMLIMIT'} if($ENV{'CURL_MEMLIMIT'});

        if(-r "core") {
            # there's core file present now!
            logmsg " core dumped\n";
            $dumped_core = 1;
            $fail = 2;
        }

        if($valgrind) {
            my @e = valgrindparse("$LOGDIR/valgrind$testnum");
            if(@e && $e[0]) {
                if($automakestyle) {
                    logmsg "FAIL: torture $testnum - valgrind\n";
                }
                else {
                    logmsg " valgrind ERROR ";
                    logmsg @e;
                }
                $fail = 1;
            }
        }

        # verify that it returns a proper error code, doesn't leak memory
        # and doesn't core dump
        if(($ret & 255) || ($ret >> 8) >= 128) {
            logmsg " system() returned $ret\n";
            $fail=1;
        }
        else {
            my @memdata=`$memanalyze $memdump`;
            my $leak=0;
            for(@memdata) {
                if($_ ne "") {
                    # well it could be other memory problems as well, but
                    # we call it leak for short here
                    $leak=1;
                }
            }
            if($leak) {
                logmsg "** MEMORY FAILURE\n";
                logmsg @memdata;
                logmsg `$memanalyze -l $memdump`;
                $fail = 1;
            }
        }
        if($fail) {
            logmsg " Failed on function number $limit in test.\n",
            " invoke with \"-t$limit\" to repeat this single case.\n";
            stopservers($verbose);
            return 1;
        }
    }

    logmsg "\n" if($verbose);
    logmsg "torture OK\n";
    return 0;
}


#######################################################################
# restore environment variables that were modified in test
sub restore_test_env {
    my $deleteoldenv = $_[0];   # 1 to delete the saved contents after restore
    foreach my $var (keys %oldenv) {
        if($oldenv{$var} eq 'notset') {
            delete $ENV{$var} if($ENV{$var});
        }
        else {
            $ENV{$var} = $oldenv{$var};
        }
        if($deleteoldenv) {
            delete $oldenv{$var};
        }
    }
}


#######################################################################
# Start the servers needed to run this test case
sub singletest_startservers {
    my ($testnum, $testtimings) = @_;

    # remove old test server files before servers are started/verified
    unlink($FTPDCMD);
    unlink($SERVERIN);
    unlink($SERVER2IN);
    unlink($PROXYIN);

    # timestamp required servers verification start
    $$testtimings{"timesrvrini"} = Time::HiRes::time();

    my $why;
    my $error;
    if (!$listonly) {
        my @what = getpart("client", "server");
        if(!$what[0]) {
            warn "Test case $testnum has no server(s) specified";
            $why = "no server specified";
            $error = -1;
        } else {
            my $err;
            ($why, $err) = serverfortest(@what);
            if($err == 1) {
                # Error indicates an actual problem starting the server
                $error = -2;
            } else {
                $error = -1;
            }
        }
    }

    # timestamp required servers verification end
    $$testtimings{"timesrvrend"} = Time::HiRes::time();

    return ($why, $error);
}


#######################################################################
# Generate preprocessed test file
sub singletest_preprocess {
    my $testnum = $_[0];

    # Save a preprocessed version of the entire test file. This allows more
    # "basic" test case readers to enjoy variable replacements.
    my @entiretest = fulltest();
    my $otest = "$LOGDIR/test$testnum";

    @entiretest = prepro($testnum, @entiretest);

    # save the new version
    open(my $fulltesth, ">", "$otest") || die "Failure writing test file";
    foreach my $bytes (@entiretest) {
        print $fulltesth pack('a*', $bytes) or die "Failed to print '$bytes': $!";
    }
    close($fulltesth) || die "Failure writing test file";

    # in case the process changed the file, reload it
    loadtest("$LOGDIR/test${testnum}");
}


#######################################################################
# Set up the test environment to run this test case
sub singletest_setenv {
    my @setenv = getpart("client", "setenv");
    foreach my $s (@setenv) {
        chomp $s;
        if($s =~ /([^=]*)=(.*)/) {
            my ($var, $content) = ($1, $2);
            # remember current setting, to restore it once test runs
            $oldenv{$var} = ($ENV{$var})?"$ENV{$var}":'notset';
            # set new value
            if(!$content) {
                delete $ENV{$var} if($ENV{$var});
            }
            else {
                if($var =~ /^LD_PRELOAD/) {
                    if(exe_ext('TOOL') && (exe_ext('TOOL') eq '.exe')) {
                        logmsg "Skipping LD_PRELOAD due to lack of OS support\n" if($verbose);
                        next;
                    }
                    if($feature{"debug"} || !$has_shared) {
                        logmsg "Skipping LD_PRELOAD due to no release shared build\n" if($verbose);
                        next;
                    }
                }
                $ENV{$var} = "$content";
                logmsg "setenv $var = $content\n" if($verbose);
            }
        }
    }
    if($proxy_address) {
        $ENV{http_proxy} = $proxy_address;
        $ENV{HTTPS_PROXY} = $proxy_address;
    }
}


#######################################################################
# Check that test environment is fine to run this test case
sub singletest_precheck {
    my $testnum = $_[0];
    my $why;
    my @precheck = getpart("client", "precheck");
    if(@precheck) {
        my $cmd = $precheck[0];
        chomp $cmd;
        if($cmd) {
            my @p = split(/ /, $cmd);
            if($p[0] !~ /\//) {
                # the first word, the command, does not contain a slash so
                # we will scan the "improved" PATH to find the command to
                # be able to run it
                my $fullp = checktestcmd($p[0]);

                if($fullp) {
                    $p[0] = $fullp;
                }
                $cmd = join(" ", @p);
            }

            my @o = `$cmd 2> $LOGDIR/precheck-$testnum`;
            if($o[0]) {
                $why = $o[0];
                $why =~ s/[\r\n]//g;
            }
            elsif($?) {
                $why = "precheck command error";
            }
            logmsg "prechecked $cmd\n" if($verbose);
        }
    }
    return $why;
}


#######################################################################
# Prepare the test environment to run this test case
sub singletest_prepare {
    my ($testnum) = @_;

    if($feature{"TrackMemory"}) {
        unlink($memdump);
    }
    unlink("core");

    # remove server output logfiles after servers are started/verified
    unlink($SERVERIN);
    unlink($SERVER2IN);
    unlink($PROXYIN);

    # if this section exists, it might be FTP server instructions:
    my @ftpservercmd = getpart("reply", "servercmd");
    push @ftpservercmd, "Testnum $testnum\n";
    # write the instructions to file
    writearray($FTPDCMD, \@ftpservercmd);

    # create (possibly-empty) files before starting the test
    for my $partsuffix (('', '1', '2', '3', '4')) {
        my @inputfile=getpart("client", "file".$partsuffix);
        my %fileattr = getpartattr("client", "file".$partsuffix);
        my $filename=$fileattr{'name'};
        if(@inputfile || $filename) {
            if(!$filename) {
                logmsg "ERROR: section client=>file has no name attribute\n";
                return -1;
            }
            my $fileContent = join('', @inputfile);

            # make directories if needed
            my $path = $filename;
            # cut off the file name part
            $path =~ s/^(.*)\/[^\/]*/$1/;
            my @parts = split(/\//, $path);
            if($parts[0] eq $LOGDIR) {
                # the file is in $LOGDIR/
                my $d = shift @parts;
                for(@parts) {
                    $d .= "/$_";
                    mkdir $d; # 0777
                }
            }
            if (open(my $outfile, ">", "$filename")) {
                binmode $outfile; # for crapage systems, use binary
                if($fileattr{'nonewline'}) {
                    # cut off the final newline
                    chomp($fileContent);
                }
                print $outfile $fileContent;
                close($outfile);
            } else {
                logmsg "ERROR: cannot write $filename\n";
            }
        }
    }
    return 0;
}


#######################################################################
# Run the test command
sub singletest_run {
    my ($testnum, $testtimings) = @_;

    # get the command line options to use
    my ($cmd, @blaha)= getpart("client", "command");
    if($cmd) {
        # make some nice replace operations
        $cmd =~ s/\n//g; # no newlines please
        # substitute variables in the command line
    }
    else {
        # there was no command given, use something silly
        $cmd="-";
    }

    my $CURLOUT="$LOGDIR/curl$testnum.out"; # curl output if not stdout

    # if stdout section exists, we verify that the stdout contained this:
    my $out="";
    my %cmdhash = getpartattr("client", "command");
    if((!$cmdhash{'option'}) || ($cmdhash{'option'} !~ /no-output/)) {
        #We may slap on --output!
        if (!partexists("verify", "stdout") ||
                ($cmdhash{'option'} && $cmdhash{'option'} =~ /force-output/)) {
            $out=" --output $CURLOUT ";
        }
    }

    # redirected stdout/stderr to these files
    $STDOUT="$LOGDIR/stdout$testnum";
    $STDERR="$LOGDIR/stderr$testnum";

    my @codepieces = getpart("client", "tool");
    my $tool="";
    if(@codepieces) {
        $tool = $codepieces[0];
        chomp $tool;
        $tool .= exe_ext('TOOL');
    }

    my $disablevalgrind;
    my $CMDLINE="";
    my $cmdargs;
    my $cmdtype = $cmdhash{'type'} || "default";
    my $fail_due_event_based = $run_event_based;
    if($cmdtype eq "perl") {
        # run the command line prepended with "perl"
        $cmdargs ="$cmd";
        $CMDLINE = "$perl ";
        $tool=$CMDLINE;
        $disablevalgrind=1;
    }
    elsif($cmdtype eq "shell") {
        # run the command line prepended with "/bin/sh"
        $cmdargs ="$cmd";
        $CMDLINE = "/bin/sh ";
        $tool=$CMDLINE;
        $disablevalgrind=1;
    }
    elsif(!$tool && !$keywords{"unittest"}) {
        # run curl, add suitable command line options
        my $inc="";
        if((!$cmdhash{'option'}) || ($cmdhash{'option'} !~ /no-include/)) {
            $inc = " --include";
        }
        $cmdargs = "$out$inc ";

        if($cmdhash{'option'} && ($cmdhash{'option'} =~ /binary-trace/)) {
            $cmdargs .= "--trace $LOGDIR/trace$testnum ";
        }
        else {
            $cmdargs .= "--trace-ascii $LOGDIR/trace$testnum ";
        }
        $cmdargs .= "--trace-time ";
        if($run_event_based) {
            $cmdargs .= "--test-event ";
            $fail_due_event_based--;
        }
        $cmdargs .= $cmd;
        if ($proxy_address) {
            $cmdargs .= " --proxy $proxy_address ";
        }
    }
    else {
        $cmdargs = " $cmd"; # $cmd is the command line for the test file
        $CURLOUT = $STDOUT; # sends received data to stdout

        # Default the tool to a unit test with the same name as the test spec
        if($keywords{"unittest"} && !$tool) {
            $tool="unit$testnum";
        }

        if($tool =~ /^lib/) {
            $CMDLINE="$LIBDIR/$tool";
        }
        elsif($tool =~ /^unit/) {
            $CMDLINE="$UNITDIR/$tool";
        }

        if(! -f $CMDLINE) {
            logmsg "The tool set in the test case for this: '$tool' does not exist\n";
            return (-1, 0, 0, "", "", 0);
        }
        $DBGCURL=$CMDLINE;
    }

    if($fail_due_event_based) {
        logmsg "This test cannot run event based\n";
        return (-1, 0, 0, "", "", 0);
    }

    if($gdbthis) {
        # gdb is incompatible with valgrind, so disable it when debugging
        # Perhaps a better approach would be to run it under valgrind anyway
        # with --db-attach=yes or --vgdb=yes.
        $disablevalgrind=1;
    }

    my @stdintest = getpart("client", "stdin");

    if(@stdintest) {
        my $stdinfile="$LOGDIR/stdin-for-$testnum";

        my %hash = getpartattr("client", "stdin");
        if($hash{'nonewline'}) {
            # cut off the final newline from the final line of the stdin data
            chomp($stdintest[-1]);
        }

        writearray($stdinfile, \@stdintest);

        $cmdargs .= " <$stdinfile";
    }

    if(!$tool) {
        $CMDLINE="$CURL";
    }

    if(use_valgrind() && !$disablevalgrind) {
        my $valgrindcmd = "$valgrind ";
        $valgrindcmd .= "$valgrind_tool " if($valgrind_tool);
        $valgrindcmd .= "--quiet --leak-check=yes ";
        $valgrindcmd .= "--suppressions=$srcdir/valgrind.supp ";
        # $valgrindcmd .= "--gen-suppressions=all ";
        $valgrindcmd .= "--num-callers=16 ";
        $valgrindcmd .= "${valgrind_logfile}=$LOGDIR/valgrind$testnum";
        $CMDLINE = "$valgrindcmd $CMDLINE";
    }

    $CMDLINE .= "$cmdargs >$STDOUT 2>$STDERR";

    if($verbose) {
        logmsg "$CMDLINE\n";
    }

    open(my $cmdlog, ">", $CURLLOG) || die "Failure writing log file";
    print $cmdlog "$CMDLINE\n";
    close($cmdlog) || die "Failure writing log file";

    my $dumped_core;
    my $cmdres;

    if($gdbthis) {
        my $gdbinit = "$TESTDIR/gdbinit$testnum";
        open(my $gdbcmd, ">", "$LOGDIR/gdbcmd") || die "Failure writing gdb file";
        print $gdbcmd "set args $cmdargs\n";
        print $gdbcmd "show args\n";
        print $gdbcmd "source $gdbinit\n" if -e $gdbinit;
        close($gdbcmd) || die "Failure writing gdb file";
    }

    # Flush output.
    $| = 1;

    # timestamp starting of test command
    $$testtimings{"timetoolini"} = Time::HiRes::time();

    # run the command line we built
    if ($torture) {
        $cmdres = torture($CMDLINE,
                          $testnum,
                          "$gdb --directory $LIBDIR $DBGCURL -x $LOGDIR/gdbcmd");
    }
    elsif($gdbthis) {
        my $GDBW = ($gdbxwin) ? "-w" : "";
        runclient("$gdb --directory $LIBDIR $DBGCURL $GDBW -x $LOGDIR/gdbcmd");
        $cmdres=0; # makes it always continue after a debugged run
    }
    else {
        # Convert the raw result code into a more useful one
        ($cmdres, $dumped_core) = normalize_cmdres(runclient("$CMDLINE"));
    }

    # timestamp finishing of test command
    $$testtimings{"timetoolend"} = Time::HiRes::time();

    return (0, $cmdres, $dumped_core, $CURLOUT, $tool, use_valgrind() && !$disablevalgrind);
}


#######################################################################
# Clean up after test command
sub singletest_clean {
    my ($testnum, $dumped_core, $testtimings)=@_;

    if(!$dumped_core) {
        if(-r "core") {
            # there's core file present now!
            $dumped_core = 1;
        }
    }

    if($dumped_core) {
        logmsg "core dumped\n";
        if(0 && $gdb) {
            logmsg "running gdb for post-mortem analysis:\n";
            open(my $gdbcmd, ">", "$LOGDIR/gdbcmd2") || die "Failure writing gdb file";
            print $gdbcmd "bt\n";
            close($gdbcmd) || die "Failure writing gdb file";
            runclient("$gdb --directory libtest -x $LOGDIR/gdbcmd2 -batch $DBGCURL core ");
     #       unlink("$LOGDIR/gdbcmd2");
        }
    }

    # If a server logs advisor read lock file exists, it is an indication
    # that the server has not yet finished writing out all its log files,
    # including server request log files used for protocol verification.
    # So, if the lock file exists the script waits here a certain amount
    # of time until the server removes it, or the given time expires.
    my $serverlogslocktimeout = $defserverlogslocktimeout;
    my %cmdhash = getpartattr("client", "command");
    if($cmdhash{'timeout'}) {
        # test is allowed to override default server logs lock timeout
        if($cmdhash{'timeout'} =~ /(\d+)/) {
            $serverlogslocktimeout = $1 if($1 >= 0);
        }
    }
    if($serverlogslocktimeout) {
        my $lockretry = $serverlogslocktimeout * 20;
        while((-f $SERVERLOGS_LOCK) && $lockretry--) {
            portable_sleep(0.05);
        }
        if(($lockretry < 0) &&
           ($serverlogslocktimeout >= $defserverlogslocktimeout)) {
            logmsg "Warning: server logs lock timeout ",
                   "($serverlogslocktimeout seconds) expired\n";
        }
    }

    # Test harness ssh server does not have this synchronization mechanism,
    # this implies that some ssh server based tests might need a small delay
    # once that the client command has run to avoid false test failures.
    #
    # gnutls-serv also lacks this synchronization mechanism, so gnutls-serv
    # based tests might need a small delay once that the client command has
    # run to avoid false test failures.
    my $postcommanddelay = $defpostcommanddelay;
    if($cmdhash{'delay'}) {
        # test is allowed to specify a delay after command is executed
        if($cmdhash{'delay'} =~ /(\d+)/) {
            $postcommanddelay = $1 if($1 > 0);
        }
    }

    portable_sleep($postcommanddelay) if($postcommanddelay);

    # timestamp removal of server logs advisor read lock
    $$testtimings{"timesrvrlog"} = Time::HiRes::time();

    # test definition might instruct to stop some servers
    # stop also all servers relative to the given one

    my @killtestservers = getpart("client", "killserver");
    if(@killtestservers) {
        foreach my $server (@killtestservers) {
            chomp $server;
            if(stopserver($server)) {
                logmsg " killserver FAILED\n";
                return 1; # normal error if asked to fail on unexpected alive
            }
        }
    }
    return 0;
}

#######################################################################
# Verify that the postcheck succeeded
sub singletest_postcheck {
    my ($testnum)=@_;

    # run the postcheck command
    my @postcheck= getpart("client", "postcheck");
    if(@postcheck) {
        my $cmd = join("", @postcheck);
        chomp $cmd;
        if($cmd) {
            logmsg "postcheck $cmd\n" if($verbose);
            my $rc = runclient("$cmd");
            # Must run the postcheck command in torture mode in order
            # to clean up, but the result can't be relied upon.
            if($rc != 0 && !$torture) {
                logmsg " postcheck FAILED\n";
                return -1;
            }
        }
    }
    return 0;
}



###################################################################
# Get ready to run a single test case
sub runner_test_preprocess {
    my ($testnum)=@_;
    my %testtimings;

    if(clearlogs()) {
        logmsg "Warning: log messages were lost\n";
    }

    # timestamp test preparation start
    # TODO: this metric now shows only a portion of the prep time; better would
    # be to time singletest_preprocess below instead
    $testtimings{"timeprepini"} = Time::HiRes::time();

    ###################################################################
    # Load test metadata
    # ignore any error here--if there were one, it would have been
    # caught during the selection phase and this test would not be
    # running now
    loadtest("${TESTDIR}/test${testnum}");
    readtestkeywords();

    ###################################################################
    # Start the servers needed to run this test case
    my ($why, $error) = singletest_startservers($testnum, \%testtimings);

    if(!$why) {

        ###############################################################
        # Generate preprocessed test file
        # This must be done after the servers are started so server
        # variables are available for substitution.
        singletest_preprocess($testnum);

        ###############################################################
        # Set up the test environment to run this test case
        singletest_setenv();

        ###############################################################
        # Check that the test environment is fine to run this test case
        if (!$listonly) {
            $why = singletest_precheck($testnum);
            $error = -1;
        }
    }
    return ($why, $error, clearlogs(), \%testtimings);
}


###################################################################
# Run a single test case with an environment that already been prepared
# Returns 0=success, -1=skippable failure, -2=permanent error,
#   1=unskippable test failure, as first integer, plus any log messages,
#   plus more return values when error is 0
sub runner_test_run {
    my ($testnum)=@_;

    if(clearlogs()) {
        logmsg "Warning: log messages were lost\n";
    }

    #######################################################################
    # Prepare the test environment to run this test case
    my $error = singletest_prepare($testnum);
    if($error) {
        return (-2, clearlogs());
    }

    #######################################################################
    # Run the test command
    my %testtimings;
    my $cmdres;
    my $dumped_core;
    my $CURLOUT;
    my $tool;
    my $usedvalgrind;
    ($error, $cmdres, $dumped_core, $CURLOUT, $tool, $usedvalgrind) = singletest_run($testnum, \%testtimings);
    if($error) {
        return (-2, clearlogs(), \%testtimings);
    }

    #######################################################################
    # Clean up after test command
    $error = singletest_clean($testnum, $dumped_core, \%testtimings);
    if($error) {
        return ($error, clearlogs(), \%testtimings);
    }

    #######################################################################
    # Verify that the postcheck succeeded
    $error = singletest_postcheck($testnum);
    if($error) {
        return ($error, clearlogs(), \%testtimings);
    }

    #######################################################################
    # restore environment variables that were modified
    restore_test_env(0);

    return (0, clearlogs(), \%testtimings, $cmdres, $CURLOUT, $tool, $usedvalgrind);
}


###################################################################
# Kill the server processes that still have lock files in a directory
sub runner_clearlocks {
    my ($lockdir)=@_;
    if(clearlogs()) {
        logmsg "Warning: log messages were lost\n";
    }
    clearlocks($lockdir);
    return clearlogs();
}


###################################################################
# Kill all server processes
sub runner_stopservers {
    my $error = stopservers($verbose);
    my $logs = clearlogs();
    return ($error, $logs);
}


1;
