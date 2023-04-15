#!/usr/bin/env perl
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

# Experimental hooks are available to run tests remotely on machines that
# are able to run curl but are unable to run the test harness.
# The following sections need to be modified:
#
#  $HOSTIP, $HOST6IP - Set to the address of the host running the test suite
#  $CLIENTIP, $CLIENT6IP - Set to the address of the host running curl
#  runclient, runclientoutput - Modify to copy all the files in the log/
#    directory to the system running curl, run the given command remotely
#    and save the return code or returned stdout (respectively), then
#    copy all the files from the remote system's log/ directory back to
#    the host running the test suite.  This can be done a few ways, such
#    as using scp & ssh, rsync & telnet, or using a NFS shared directory
#    and ssh.
#
# 'make && make test' needs to be done on both machines before making the
# above changes and running runtests.pl manually.  In the shared NFS case,
# the contents of the tests/server/ directory must be from the host
# running the test suite, while the rest must be from the host running curl.
#
# Note that even with these changes a number of tests will still fail (mainly
# to do with cookies, those that set environment variables, or those that
# do more than touch the file system in a <precheck> or <postcheck>
# section). These can be added to the $TESTCASES line below,
# e.g. $TESTCASES="!8 !31 !63 !cookies..."
#
# Finally, to properly support -g and -n, checktestcmd needs to change
# to check the remote system's PATH, and the places in the code where
# the curl binary is read directly to determine its type also need to be
# fixed. As long as the -g option is never given, and the -n is always
# given, this won't be a problem.

use strict;
# Promote all warnings to fatal
use warnings FATAL => 'all';
use 5.006;

# These should be the only variables that might be needed to get edited:

BEGIN {
    # Define srcdir to the location of the tests source directory. This is
    # usually set by the Makefile, but for out-of-tree builds with direct
    # invocation of runtests.pl, it may not be set.
    if(!defined $ENV{'srcdir'}) {
        use File::Basename;
        $ENV{'srcdir'} = dirname(__FILE__);
    }
    push(@INC, $ENV{'srcdir'});
    # run time statistics needs Time::HiRes
    eval {
        no warnings "all";
        require Time::HiRes;
        import  Time::HiRes qw( time );
    }
}

use Cwd;
use Digest::MD5 qw(md5);
use MIME::Base64;
use List::Util 'sum';

use pathhelp qw(
    exe_ext
    sys_native_current_path
    );
use processhelp qw(
    portable_sleep
    );

use appveyor;
use azure;
use getpart;   # array functions
use servers;
use valgrind;  # valgrind report parser
use globalconfig;

my $CLIENTIP="127.0.0.1"; # address which curl uses for incoming connections
my $CLIENT6IP="[::1]";    # address which curl uses for incoming connections

my %custom_skip_reasons;

my $CURLVERSION="";          # curl's reported version number

my $ACURL=$VCURL;  # what curl binary to use to talk to APIs (relevant for CI)
                   # ACURL is handy to set to the system one for reliability
my $DBGCURL=$CURL; #"../src/.libs/curl";  # alternative for debugging
my $TESTDIR="$srcdir/data";
my $LIBDIR="./libtest";
my $UNITDIR="./unit";
# TODO: $LOGDIR could eventually change later on, so must regenerate all the
# paths depending on it after $LOGDIR itself changes.
# TODO: change this to use server_inputfilename()
my $SERVERIN="$LOGDIR/server.input"; # what curl sent the server
my $SERVER2IN="$LOGDIR/server2.input"; # what curl sent the second server
my $PROXYIN="$LOGDIR/proxy.input"; # what curl sent the proxy
my $CURLLOG="$LOGDIR/commands.log"; # all command lines run
my $SERVERLOGS_LOCK="$LOGDIR/serverlogs.lock"; # server logs advisor read lock
my $CURLCONFIG="../curl-config"; # curl-config from current build

# Normally, all test cases should be run, but at times it is handy to
# simply run a particular one:
my $TESTCASES="all";

# To run specific test cases, set them like:
# $TESTCASES="1 2 3 7 8";

#######################################################################
# No variables below this point should need to be modified
#

my $libtool;
my $repeat = 0;

# name of the file that the memory debugging creates:
my $memdump="$LOGDIR/memdump";

# the path to the script that analyzes the memory debug output file:
my $memanalyze="$perl $srcdir/memanalyze.pl";

my $pwd = getcwd();          # current working directory
my $posix_pwd = $pwd;

my $start;          # time at which testing started
my $valgrind = checktestcmd("valgrind");
my $valgrind_logfile="--logfile";  # the option name for valgrind 2.X
my $valgrind_tool;
my $gdb = checktestcmd("gdb");

my $uname_release = `uname -r`;
my $is_wsl = $uname_release =~ /Microsoft$/;

my $http_ipv6;      # set if HTTP server has IPv6 support
my $http_unix;      # set if HTTP server has Unix sockets support
my $ftp_ipv6;       # set if FTP server has IPv6 support

# this version is decided by the particular nghttp2 library that is being used
my $h2cver = "h2c";

my $has_shared;     # built as a shared library

my $resolver;       # name of the resolver backend (for human presentation)

my $has_textaware;  # set if running on a system that has a text mode concept
                    # on files. Windows for example

my %skipped;    # skipped{reason}=counter, reasons for skip
my @teststat;   # teststat[testnum]=reason, reasons for skip
my %disabled_keywords;  # key words of tests to skip
my %ignored_keywords;   # key words of tests to ignore results
my %enabled_keywords;   # key words of tests to run
my %disabled;           # disabled test cases
my %ignored;            # ignored results of test cases

my $defserverlogslocktimeout = 2; # timeout to await server logs lock removal
my $defpostcommanddelay = 0; # delay between command and postcheck sections

my $timestats;   # time stamping and stats generation
my $fullstats;   # show time stats for every single test
my %timeprepini; # timestamp for each test preparation start
my %timesrvrini; # timestamp for each test required servers verification start
my %timesrvrend; # timestamp for each test required servers verification end
my %timetoolini; # timestamp for each test command run starting
my %timetoolend; # timestamp for each test command run stopping
my %timesrvrlog; # timestamp for each test server logs lock removal
my %timevrfyend; # timestamp for each test result verification end

my %oldenv;       # environment variables before test is started
my %feature;      # array of enabled features
my %keywords;     # array of keywords from the test spec

#######################################################################
# variables that command line options may set
#

my $short;
my $automakestyle;
my $no_debuginfod;
my $anyway;
my $gdbthis;      # run test case with gdb debugger
my $gdbxwin;      # use windowed gdb when using gdb
my $keepoutfiles; # keep stdout and stderr files after tests
my $clearlocks;   # force removal of files by killing locking processes
my $listonly;     # only list the tests
my $postmortem;   # display detailed info about failed tests
my $run_event_based; # run curl with --test-event to test the event API
my $run_disabled; # run the specific tests even if listed in DISABLED
my $scrambleorder;

# torture test variables
my $tortalloc;
my $shallow;
my $randseed = 0;

# Azure Pipelines specific variables
my $AZURE_RUN_ID = 0;
my $AZURE_RESULT_ID = 0;

#######################################################################
# logmsg is our general message logging subroutine.
#
sub logmsg {
    for(@_) {
        my $line = $_;
        if ($is_wsl) {
            # use \r\n for WSL shell
            $line =~ s/\r?\n$/\r\n/g;
        }
        print "$line";
    }
}

# enable memory debugging if curl is compiled with it
$ENV{'CURL_MEMDEBUG'} = $memdump;
$ENV{'CURL_ENTROPY'}="12345678";
$ENV{'CURL_FORCETIME'}=1; # for debug NTLM magic
$ENV{'CURL_GLOBAL_INIT'}=1; # debug curl_global_init/cleanup use
$ENV{'HOME'}=$pwd;
$ENV{'CURL_HOME'}=$ENV{'HOME'};
$ENV{'XDG_CONFIG_HOME'}=$ENV{'HOME'};
$ENV{'COLUMNS'}=79; # screen width!

sub catch_zap {
    my $signame = shift;
    logmsg "runtests.pl received SIG$signame, exiting\n";
    stopservers($verbose);
    die "Somebody sent me a SIG$signame";
}
$SIG{INT} = \&catch_zap;
$SIG{TERM} = \&catch_zap;

##########################################################################
# Clear all possible '*_proxy' environment variables for various protocols
# to prevent them to interfere with our testing!

foreach my $protocol (('ftp', 'http', 'ftps', 'https', 'no', 'all')) {
    my $proxy = "${protocol}_proxy";
    # clear lowercase version
    delete $ENV{$proxy} if($ENV{$proxy});
    # clear uppercase version
    delete $ENV{uc($proxy)} if($ENV{uc($proxy)});
}

# make sure we don't get affected by other variables that control our
# behavior

delete $ENV{'SSL_CERT_DIR'} if($ENV{'SSL_CERT_DIR'});
delete $ENV{'SSL_CERT_PATH'} if($ENV{'SSL_CERT_PATH'});
delete $ENV{'CURL_CA_BUNDLE'} if($ENV{'CURL_CA_BUNDLE'});

# provide defaults from our config file for ENV vars not explicitly
# set by the caller
if (open(my $fd, "<", "config")) {
    while(my $line = <$fd>) {
        next if ($line =~ /^#/);
        chomp $line;
        my ($name, $val) = split(/\s*:\s*/, $line, 2);
        $ENV{$name} = $val if(!$ENV{$name});
    }
    close($fd);
}

# Check if we have nghttpx available and if it talks http/3
my $nghttpx_h3 = 0;
if (!$ENV{"NGHTTPX"}) {
    $ENV{"NGHTTPX"} = checktestcmd("nghttpx");
}
if ($ENV{"NGHTTPX"}) {
    my $nghttpx_version=join(' ', `"$ENV{'NGHTTPX'} -v 2>/dev/null"`);
    $nghttpx_h3 = $nghttpx_version =~ /nghttp3\//;
    chomp $nghttpx_h3;
}


#######################################################################
# Get the list of tests that the tests/data/Makefile.am knows about!
#
my $disttests = "";
sub get_disttests {
    # If a non-default $TESTDIR is being used there may not be any
    # Makefile.inc in which case there's nothing to do.
    open(my $dh, "<", "$TESTDIR/Makefile.inc") or return;
    while(<$dh>) {
        chomp $_;
        if(($_ =~ /^#/) ||($_ !~ /test/)) {
            next;
        }
        $disttests .= $_;
    }
    close($dh);
}

#######################################################################
# Check for a command in the PATH of the machine running curl.
#
sub checktestcmd {
    my ($cmd)=@_;
    my @testpaths=("$LIBDIR/.libs", "$LIBDIR");
    return checkcmd($cmd, @testpaths);
}

#######################################################################
# Run the application under test and return its return code
#
sub runclient {
    my ($cmd)=@_;
    my $ret = system($cmd);
    print "CMD ($ret): $cmd\n" if($verbose && !$torture);
    return $ret;

# This is one way to test curl on a remote machine
#    my $out = system("ssh $CLIENTIP cd \'$pwd\' \\; \'$cmd\'");
#    sleep 2;    # time to allow the NFS server to be updated
#    return $out;
}

#######################################################################
# Run the application under test and return its stdout
#
sub runclientoutput {
    my ($cmd)=@_;
    return `$cmd 2>/dev/null`;

# This is one way to test curl on a remote machine
#    my @out = `ssh $CLIENTIP cd \'$pwd\' \\; \'$cmd\'`;
#    sleep 2;    # time to allow the NFS server to be updated
#    return @out;
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

    logmsg "torture OK\n";
    return 0;
}


#######################################################################
# Remove all files in the specified directory
#
sub cleardir {
    my $dir = $_[0];
    my $done = 1;  # success
    my $file;

    # Get all files
    opendir(my $dh, $dir) ||
        return 0; # can't open dir
    while($file = readdir($dh)) {
        # Don't clear the $PIDDIR since those need to live beyond one test
        if(($file !~ /^(\.|\.\.)\z/) && "$dir/$file" ne $PIDDIR) {
            if(-d "$dir/$file") {
                if(!cleardir("$dir/$file")) {
                    $done = 0;
                }
                if(!rmdir("$dir/$file")) {
                    $done = 0;
                }
            }
            else {
                # Ignore stunnel since we cannot do anything about its locks
                if(!unlink("$dir/$file") && "$file" !~ /_stunnel\.log$/) {
                    $done = 0;
                }
            }
        }
    }
    closedir $dh;
    return $done;
}

#######################################################################
# compare test results with the expected output, we might filter off
# some pattern that is allowed to differ, output test results
#
sub compare {
    my ($testnum, $testname, $subject, $firstref, $secondref)=@_;

    my $result = compareparts($firstref, $secondref);

    if($result) {
        # timestamp test result verification end
        $timevrfyend{$testnum} = Time::HiRes::time();

        if(!$short) {
            logmsg "\n $testnum: $subject FAILED:\n";
            logmsg showdiff($LOGDIR, $firstref, $secondref);
        }
        elsif(!$automakestyle) {
            logmsg "FAILED\n";
        }
        else {
            # automakestyle
            logmsg "FAIL: $testnum - $testname - $subject\n";
        }
    }
    return $result;
}

#######################################################################
# Check & display information about curl and the host the test suite runs on.
# Information to do with servers is displayed in displayserverfeatures, after
# the server initialization is performed.
sub checksystemfeatures {
    my $feat;
    my $curl;
    my $libcurl;
    my $versretval;
    my $versnoexec;
    my @version=();
    my @disabled;
    my $dis = "";

    my $curlverout="$LOGDIR/curlverout.log";
    my $curlvererr="$LOGDIR/curlvererr.log";
    my $versioncmd="$CURL --version 1>$curlverout 2>$curlvererr";

    unlink($curlverout);
    unlink($curlvererr);

    $versretval = runclient($versioncmd);
    $versnoexec = $!;

    open(my $versout, "<", "$curlverout");
    @version = <$versout>;
    close($versout);

    open(my $disabledh, "-|", "server/disabled".exe_ext('TOOL'));
    @disabled = <$disabledh>;
    close($disabledh);

    if($disabled[0]) {
        s/[\r\n]//g for @disabled;
        $dis = join(", ", @disabled);
    }

    $resolver="stock";
    for(@version) {
        chomp;

        if($_ =~ /^curl ([^ ]*)/) {
            $curl = $_;
            $CURLVERSION = $1;
            $curl =~ s/^(.*)(libcurl.*)/$1/g || die "Failure determining curl binary version";

            $libcurl = $2;
            if($curl =~ /linux|bsd|solaris/) {
                # system support LD_PRELOAD; may be disabled later
                $feature{"ld_preload"} = 1;
            }
            if($curl =~ /win32|Windows|mingw(32|64)/) {
                # This is a Windows MinGW build or native build, we need to use
                # Win32-style path.
                $pwd = sys_native_current_path();
                $has_textaware = 1;
                $feature{"win32"} = 1;
                # set if built with MinGW (as opposed to MinGW-w64)
                $feature{"MinGW"} = 1 if ($curl =~ /-pc-mingw32/);
            }
           if ($libcurl =~ /\s(winssl|schannel)\b/i) {
               $feature{"Schannel"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\sopenssl\b/i) {
               $feature{"OpenSSL"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\sgnutls\b/i) {
               $feature{"GnuTLS"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\srustls-ffi\b/i) {
               $feature{"rustls"} = 1;
           }
           elsif ($libcurl =~ /\snss\b/i) {
               $feature{"NSS"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\swolfssl\b/i) {
               $feature{"wolfssl"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\sbearssl\b/i) {
               $feature{"bearssl"} = 1;
           }
           elsif ($libcurl =~ /\ssecuretransport\b/i) {
               $feature{"sectransp"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\sBoringSSL\b/i) {
               # OpenSSL compatible API
               $feature{"OpenSSL"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\slibressl\b/i) {
               # OpenSSL compatible API
               $feature{"OpenSSL"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           elsif ($libcurl =~ /\smbedTLS\b/i) {
               $feature{"mbedtls"} = 1;
               $feature{"SSLpinning"} = 1;
           }
           if ($libcurl =~ /ares/i) {
               $feature{"c-ares"} = 1;
               $resolver="c-ares";
           }
           if ($libcurl =~ /Hyper/i) {
               $feature{"hyper"} = 1;
           }
            if ($libcurl =~ /nghttp2/i) {
                # nghttp2 supports h2c, hyper does not
                $feature{"h2c"} = 1;
            }
            if ($libcurl =~ /libssh2/i) {
                $feature{"libssh2"} = 1;
            }
            if ($libcurl =~ /libssh\/([0-9.]*)\//i) {
                $feature{"libssh"} = 1;
                if($1 =~ /(\d+)\.(\d+).(\d+)/) {
                    my $v = $1 * 100 + $2 * 10 + $3;
                    if($v < 94) {
                        # before 0.9.4
                        $feature{"oldlibssh"} = 1;
                    }
                }
            }
            if ($libcurl =~ /wolfssh/i) {
                $feature{"wolfssh"} = 1;
            }
        }
        elsif($_ =~ /^Protocols: (.*)/i) {
            # these are the protocols compiled in to this libcurl
            @protocols = split(' ', lc($1));

            # Generate a "proto-ipv6" version of each protocol to match the
            # IPv6 <server> name and a "proto-unix" to match the variant which
            # uses Unix domain sockets. This works even if support isn't
            # compiled in because the <features> test will fail.
            push @protocols, map(("$_-ipv6", "$_-unix"), @protocols);

            # 'http-proxy' is used in test cases to do CONNECT through
            push @protocols, 'http-proxy';

            # 'none' is used in test cases to mean no server
            push @protocols, 'none';
        }
        elsif($_ =~ /^Features: (.*)/i) {
            $feat = $1;

            # built with memory tracking support (--enable-curldebug); may be disabled later
            $feature{"TrackMemory"} = $feat =~ /TrackMemory/i;
            # curl was built with --enable-debug
            $feature{"debug"} = $feat =~ /debug/i;
            # ssl enabled
            $feature{"SSL"} = $feat =~ /SSL/i;
            # multiple ssl backends available.
            $feature{"MultiSSL"} = $feat =~ /MultiSSL/i;
            # large file support
            $feature{"large_file"} = $feat =~ /Largefile/i;
            # IDN support
            $feature{"idn"} = $feat =~ /IDN/i;
            # IPv6 support
            $feature{"ipv6"} = $feat =~ /IPv6/i;
            # Unix sockets support
            $feature{"unix-sockets"} = $feat =~ /UnixSockets/i;
            # libz compression
            $feature{"libz"} = $feat =~ /libz/i;
            # Brotli compression
            $feature{"brotli"} = $feat =~ /brotli/i;
            # Zstd compression
            $feature{"zstd"} = $feat =~ /zstd/i;
            # NTLM enabled
            $feature{"NTLM"} = $feat =~ /NTLM/i;
            # NTLM delegation to winbind daemon ntlm_auth helper enabled
            $feature{"NTLM_WB"} = $feat =~ /NTLM_WB/i;
            # SSPI enabled
            $feature{"SSPI"} = $feat =~ /SSPI/i;
            # GSS-API enabled
            $feature{"GSS-API"} = $feat =~ /GSS-API/i;
            # Kerberos enabled
            $feature{"Kerberos"} = $feat =~ /Kerberos/i;
            # SPNEGO enabled
            $feature{"SPNEGO"} = $feat =~ /SPNEGO/i;
            # CharConv enabled
            $feature{"CharConv"} = $feat =~ /CharConv/i;
            # TLS-SRP enabled
            $feature{"TLS-SRP"} = $feat =~ /TLS-SRP/i;
            # PSL enabled
            $feature{"PSL"} = $feat =~ /PSL/i;
            # alt-svc enabled
            $feature{"alt-svc"} = $feat =~ /alt-svc/i;
            # HSTS support
            $feature{"HSTS"} = $feat =~ /HSTS/i;
            if($feat =~ /AsynchDNS/i) {
                if(!$feature{"c-ares"}) {
                    # this means threaded resolver
                    $feature{"threaded-resolver"} = 1;
                    $resolver="threaded";
                }
            }
            # http2 enabled
            $feature{"http/2"} = $feat =~ /HTTP2/;
            if($feature{"http/2"}) {
                push @protocols, 'http/2';
            }
            # http3 enabled
            $feature{"http/3"} = $feat =~ /HTTP3/;
            if($feature{"http/3"}) {
                push @protocols, 'http/3';
            }
            # https proxy support
            $feature{"https-proxy"} = $feat =~ /HTTPS-proxy/;
            if($feature{"https-proxy"}) {
                # 'https-proxy' is used as "server" so consider it a protocol
                push @protocols, 'https-proxy';
            }
            # UNICODE support
            $feature{"Unicode"} = $feat =~ /Unicode/i;
            # Thread-safe init
            $feature{"threadsafe"} = $feat =~ /threadsafe/i;
        }
        #
        # Test harness currently uses a non-stunnel server in order to
        # run HTTP TLS-SRP tests required when curl is built with https
        # protocol support and TLS-SRP feature enabled. For convenience
        # 'httptls' may be included in the test harness protocols array
        # to differentiate this from classic stunnel based 'https' test
        # harness server.
        #
        if($feature{"TLS-SRP"}) {
            my $add_httptls;
            for(@protocols) {
                if($_ =~ /^https(-ipv6|)$/) {
                    $add_httptls=1;
                    last;
                }
            }
            if($add_httptls && (! grep /^httptls$/, @protocols)) {
                push @protocols, 'httptls';
                push @protocols, 'httptls-ipv6';
            }
        }
    }

    if(!$curl) {
        logmsg "unable to get curl's version, further details are:\n";
        logmsg "issued command: \n";
        logmsg "$versioncmd \n";
        if ($versretval == -1) {
            logmsg "command failed with: \n";
            logmsg "$versnoexec \n";
        }
        elsif ($versretval & 127) {
            logmsg sprintf("command died with signal %d, and %s coredump.\n",
                           ($versretval & 127), ($versretval & 128)?"a":"no");
        }
        else {
            logmsg sprintf("command exited with value %d \n", $versretval >> 8);
        }
        logmsg "contents of $curlverout: \n";
        displaylogcontent("$curlverout");
        logmsg "contents of $curlvererr: \n";
        displaylogcontent("$curlvererr");
        die "couldn't get curl's version";
    }

    if(-r "../lib/curl_config.h") {
        open(my $conf, "<", "../lib/curl_config.h");
        while(<$conf>) {
            if($_ =~ /^\#define HAVE_GETRLIMIT/) {
                # set if system has getrlimit()
                $feature{"getrlimit"} = 1;
            }
        }
        close($conf);
    }

    # allow this feature only if debug mode is disabled
    $feature{"ld_preload"} = $feature{"ld_preload"} && !$feature{"debug"};

    if($feature{"ipv6"}) {
        # client has IPv6 support

        # check if the HTTP server has it!
        my $cmd = "server/sws".exe_ext('SRV')." --version";
        my @sws = `$cmd`;
        if($sws[0] =~ /IPv6/) {
            # HTTP server has IPv6 support!
            $http_ipv6 = 1;
        }

        # check if the FTP server has it!
        $cmd = "server/sockfilt".exe_ext('SRV')." --version";
        @sws = `$cmd`;
        if($sws[0] =~ /IPv6/) {
            # FTP server has IPv6 support!
            $ftp_ipv6 = 1;
        }
    }

    if($feature{"unix-sockets"}) {
        # client has Unix sockets support, check whether the HTTP server has it
        my $cmd = "server/sws".exe_ext('SRV')." --version";
        my @sws = `$cmd`;
        $http_unix = 1 if($sws[0] =~ /unix/);
    }

    open(my $manh, "-|", "$CURL -M 2>&1");
    while(my $s = <$manh>) {
        if($s =~ /built-in manual was disabled at build-time/) {
            $feature{"manual"} = 0;
            last;
        }
        $feature{"manual"} = 1;
        last;
    }
    close($manh);

    $feature{"unittest"} = $feature{"debug"};
    $feature{"nghttpx"} = !!$ENV{'NGHTTPX'};
    $feature{"nghttpx-h3"} = !!$nghttpx_h3;

    #
    # strings that must exactly match the names used in server/disabled.c
    #
    $feature{"cookies"} = 1;
    # Use this as a proxy for any cryptographic authentication
    $feature{"crypto"} = $feature{"NTLM"} || $feature{"Kerberos"} || $feature{"SPNEGO"};
    $feature{"DoH"} = 1;
    $feature{"HTTP-auth"} = 1;
    $feature{"Mime"} = 1;
    $feature{"netrc"} = 1;
    $feature{"parsedate"} = 1;
    $feature{"proxy"} = 1;
    $feature{"shuffle-dns"} = 1;
    $feature{"typecheck"} = 1;
    $feature{"verbose-strings"} = 1;
    $feature{"wakeup"} = 1;
    $feature{"headers-api"} = 1;
    $feature{"xattr"} = 1;

    # make each protocol an enabled "feature"
    for my $p (@protocols) {
        $feature{$p} = 1;
    }
    # 'socks' was once here but is now removed

    $has_shared = `sh $CURLCONFIG --built-shared`;
    chomp $has_shared;
    $has_shared = $has_shared eq "yes";

    if(!$feature{"TrackMemory"} && $torture) {
        die "can't run torture tests since curl was built without ".
            "TrackMemory feature (--enable-curldebug)";
    }

    my $hostname=join(' ', runclientoutput("hostname"));
    my $hosttype=join(' ', runclientoutput("uname -a"));
    my $hostos=$^O;

    # display summary information about curl and the test host
    logmsg ("********* System characteristics ******** \n",
            "* $curl\n",
            "* $libcurl\n",
            "* Features: $feat\n",
            "* Disabled: $dis\n",
            "* Host: $hostname",
            "* System: $hosttype",
            "* OS: $hostos\n");

    if($feature{"TrackMemory"} && $feature{"threaded-resolver"}) {
        logmsg("*\n",
               "*** DISABLES memory tracking when using threaded resolver\n",
               "*\n");
    }

    logmsg sprintf("* Env: %s%s%s", $valgrind?"Valgrind ":"",
                   $run_event_based?"event-based ":"",
                   $nghttpx_h3);
    logmsg sprintf("%s\n", $libtool?"Libtool ":"");
    logmsg ("* Seed: $randseed\n");

    # Disable memory tracking when using threaded resolver
    $feature{"TrackMemory"} = $feature{"TrackMemory"} && !$feature{"threaded-resolver"};

    # toggle off the features that were disabled in the build
    for my $d(@disabled) {
        $feature{$d} = 0;
    }
}

#######################################################################
# display information about server features
#
sub displayserverfeatures {
    logmsg sprintf("* Servers: %s", $stunnel?"SSL ":"");
    logmsg sprintf("%s", $http_ipv6?"HTTP-IPv6 ":"");
    logmsg sprintf("%s", $http_unix?"HTTP-unix ":"");
    logmsg sprintf("%s\n", $ftp_ipv6?"FTP-IPv6 ":"");

    if($verbose) {
        if($feature{"unix-sockets"}) {
            logmsg "* Unix socket paths:\n";
            if($http_unix) {
                logmsg sprintf("*   HTTP-Unix:%s\n", $HTTPUNIXPATH);
                logmsg sprintf("*   Socks-Unix:%s\n", $SOCKSUNIXPATH);
            }
        }
    }

    logmsg "***************************************** \n";
}

#######################################################################
# substitute the variable stuff into either a joined up file or
# a command, in either case passed by reference
#
sub subVariables {
    my ($thing, $testnum, $prefix) = @_;
    my $port;

    if(!$prefix) {
        $prefix = "%";
    }

    # test server ports
    # Substitutes variables like %HTTPPORT and %SMTP6PORT with the server ports
    foreach my $proto ('DICT',
                       'FTP', 'FTP6', 'FTPS',
                       'GOPHER', 'GOPHER6', 'GOPHERS',
                       'HTTP', 'HTTP6', 'HTTPS',
                       'HTTPSPROXY', 'HTTPTLS', 'HTTPTLS6',
                       'HTTP2', 'HTTP2TLS',
                       'HTTP3',
                       'IMAP', 'IMAP6', 'IMAPS',
                       'MQTT',
                       'NOLISTEN',
                       'POP3', 'POP36', 'POP3S',
                       'RTSP', 'RTSP6',
                       'SMB', 'SMBS',
                       'SMTP', 'SMTP6', 'SMTPS',
                       'SOCKS',
                       'SSH',
                       'TELNET',
                       'TFTP', 'TFTP6') {
        $port = protoport(lc $proto);
        $$thing =~ s/${prefix}(?:$proto)PORT/$port/g;
    }
    # Special case: for PROXYPORT substitution, use httpproxy.
    $port = protoport('httpproxy');
    $$thing =~ s/${prefix}PROXYPORT/$port/g;

    # server Unix domain socket paths
    $$thing =~ s/${prefix}HTTPUNIXPATH/$HTTPUNIXPATH/g;
    $$thing =~ s/${prefix}SOCKSUNIXPATH/$SOCKSUNIXPATH/g;

    # client IP addresses
    $$thing =~ s/${prefix}CLIENT6IP/$CLIENT6IP/g;
    $$thing =~ s/${prefix}CLIENTIP/$CLIENTIP/g;

    # server IP addresses
    $$thing =~ s/${prefix}HOST6IP/$HOST6IP/g;
    $$thing =~ s/${prefix}HOSTIP/$HOSTIP/g;

    # misc
    $$thing =~ s/${prefix}CURL/$CURL/g;
    $$thing =~ s/${prefix}LOGDIR/$LOGDIR/g;
    $$thing =~ s/${prefix}PWD/$pwd/g;
    $$thing =~ s/${prefix}POSIX_PWD/$posix_pwd/g;
    $$thing =~ s/${prefix}VERSION/$CURLVERSION/g;
    $$thing =~ s/${prefix}TESTNUMBER/$testnum/g;

    my $file_pwd = $pwd;
    if($file_pwd !~ /^\//) {
        $file_pwd = "/$file_pwd";
    }
    my $ssh_pwd = $posix_pwd;
    # this only works after the SSH server has been started
    # TODO: call sshversioninfo early and store $sshdid so this substitution
    # always works
    if ($sshdid && $sshdid =~ /OpenSSH-Windows/) {
        $ssh_pwd = $file_pwd;
    }

    $$thing =~ s/${prefix}FILE_PWD/$file_pwd/g;
    $$thing =~ s/${prefix}SSH_PWD/$ssh_pwd/g;
    $$thing =~ s/${prefix}SRCDIR/$srcdir/g;
    $$thing =~ s/${prefix}USER/$USER/g;

    $$thing =~ s/${prefix}SSHSRVMD5/$SSHSRVMD5/g;
    $$thing =~ s/${prefix}SSHSRVSHA256/$SSHSRVSHA256/g;

    # The purpose of FTPTIME2 and FTPTIME3 is to provide times that can be
    # used for time-out tests and that would work on most hosts as these
    # adjust for the startup/check time for this particular host. We needed to
    # do this to make the test suite run better on very slow hosts.
    my $ftp2 = $ftpchecktime * 2;
    my $ftp3 = $ftpchecktime * 3;

    $$thing =~ s/${prefix}FTPTIME2/$ftp2/g;
    $$thing =~ s/${prefix}FTPTIME3/$ftp3/g;

    # HTTP2
    $$thing =~ s/${prefix}H2CVER/$h2cver/g;
}

sub subBase64 {
    my ($thing) = @_;

    # cut out the base64 piece
    if($$thing =~ s/%b64\[(.*)\]b64%/%%B64%%/i) {
        my $d = $1;
        # encode %NN characters
        $d =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        my $enc = encode_base64($d, "");
        # put the result into there
        $$thing =~ s/%%B64%%/$enc/;
    }
    # hex decode
    if($$thing =~ s/%hex\[(.*)\]hex%/%%HEX%%/i) {
        # decode %NN characters
        my $d = $1;
        $d =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $$thing =~ s/%%HEX%%/$d/;
    }
    if($$thing =~ s/%repeat\[(\d+) x (.*)\]%/%%REPEAT%%/i) {
        # decode %NN characters
        my ($d, $n) = ($2, $1);
        $d =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        my $all = $d x $n;
        $$thing =~ s/%%REPEAT%%/$all/;
    }
}

my $prevupdate;
sub subNewlines {
    my ($force, $thing) = @_;

    if($force) {
        # enforce CRLF newline
        $$thing =~ s/\x0d*\x0a/\x0d\x0a/;
        return;
    }

    # When curl is built with Hyper, it gets all response headers delivered as
    # name/value pairs and curl "invents" the newlines when it saves the
    # headers. Therefore, curl will always save headers with CRLF newlines
    # when built to use Hyper. By making sure we deliver all tests using CRLF
    # as well, all test comparisons will survive without knowing about this
    # little quirk.

    if(($$thing =~ /^HTTP\/(1.1|1.0|2|3) [1-5][^\x0d]*\z/) ||
       ($$thing =~ /^(GET|POST|PUT|DELETE) \S+ HTTP\/\d+(\.\d+)?/) ||
       (($$thing =~ /^[a-z0-9_-]+: [^\x0d]*\z/i) &&
        # skip curl error messages
        ($$thing !~ /^curl: \(\d+\) /))) {
        # enforce CRLF newline
        $$thing =~ s/\x0d*\x0a/\x0d\x0a/;
        $prevupdate = 1;
    }
    else {
        if(($$thing =~ /^\n\z/) && $prevupdate) {
            # if there's a blank link after a line we update, we hope it is
            # the empty line following headers
            $$thing =~ s/\x0a/\x0d\x0a/;
        }
        $prevupdate = 0;
    }
}

#######################################################################
# Provide time stamps for single test skipped events
#
sub timestampskippedevents {
    my $testnum = $_[0];

    return if((not defined($testnum)) || ($testnum < 1));

    if($timestats) {

        if($timevrfyend{$testnum}) {
            return;
        }
        elsif($timesrvrlog{$testnum}) {
            $timevrfyend{$testnum} = $timesrvrlog{$testnum};
            return;
        }
        elsif($timetoolend{$testnum}) {
            $timevrfyend{$testnum} = $timetoolend{$testnum};
            $timesrvrlog{$testnum} = $timetoolend{$testnum};
        }
        elsif($timetoolini{$testnum}) {
            $timevrfyend{$testnum} = $timetoolini{$testnum};
            $timesrvrlog{$testnum} = $timetoolini{$testnum};
            $timetoolend{$testnum} = $timetoolini{$testnum};
        }
        elsif($timesrvrend{$testnum}) {
            $timevrfyend{$testnum} = $timesrvrend{$testnum};
            $timesrvrlog{$testnum} = $timesrvrend{$testnum};
            $timetoolend{$testnum} = $timesrvrend{$testnum};
            $timetoolini{$testnum} = $timesrvrend{$testnum};
        }
        elsif($timesrvrini{$testnum}) {
            $timevrfyend{$testnum} = $timesrvrini{$testnum};
            $timesrvrlog{$testnum} = $timesrvrini{$testnum};
            $timetoolend{$testnum} = $timesrvrini{$testnum};
            $timetoolini{$testnum} = $timesrvrini{$testnum};
            $timesrvrend{$testnum} = $timesrvrini{$testnum};
        }
        elsif($timeprepini{$testnum}) {
            $timevrfyend{$testnum} = $timeprepini{$testnum};
            $timesrvrlog{$testnum} = $timeprepini{$testnum};
            $timetoolend{$testnum} = $timeprepini{$testnum};
            $timetoolini{$testnum} = $timeprepini{$testnum};
            $timesrvrend{$testnum} = $timeprepini{$testnum};
            $timesrvrini{$testnum} = $timeprepini{$testnum};
        }
    }
}

#
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
            subVariables(\$s, $testnum, "%");
            subBase64(\$s);
            subNewlines(0, \$s) if($data_crlf);
            push @out, $s;
        }
    }
    return @out;
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


# Setup CI Test Run
sub citest_starttestrun {
    if(azure_check_environment()) {
        $AZURE_RUN_ID = azure_create_test_run($ACURL);
        logmsg "Azure Run ID: $AZURE_RUN_ID\n" if ($verbose);
    }
    # Appveyor doesn't require anything here
}


# Register the test case with the CI runner
sub citest_starttest {
    my $testnum = $_[0];

    # get the name of the test early
    my $testname= (getpart("client", "name"))[0];
    chomp $testname;

    # create test result in CI services
    if(azure_check_environment() && $AZURE_RUN_ID) {
        $AZURE_RESULT_ID = azure_create_test_result($ACURL, $AZURE_RUN_ID, $testnum, $testname);
    }
    elsif(appveyor_check_environment()) {
        appveyor_create_test_result($ACURL, $testnum, $testname);
    }
}


# Submit the test case result with the CI runner
sub citest_finishtest {
    my ($testnum, $error) = @_;
    # update test result in CI services
    if(azure_check_environment() && $AZURE_RUN_ID && $AZURE_RESULT_ID) {
        $AZURE_RESULT_ID = azure_update_test_result($ACURL, $AZURE_RUN_ID, $AZURE_RESULT_ID, $testnum, $error,
                                                    $timeprepini{$testnum}, $timevrfyend{$testnum});
    }
    elsif(appveyor_check_environment()) {
        appveyor_update_test_result($ACURL, $testnum, $error, $timeprepini{$testnum}, $timevrfyend{$testnum});
    }
}

# Complete CI test run
sub citest_finishtestrun {
    if(azure_check_environment() && $AZURE_RUN_ID) {
        $AZURE_RUN_ID = azure_update_test_run($ACURL, $AZURE_RUN_ID);
    }
    # Appveyor doesn't require anything here
}


#######################################################################
# Verify that this test case should be run
sub singletest_shouldrun {
    my $testnum = $_[0];
    my $why;   # why the test won't be run
    my $errorreturncode = 1; # 1 means normal error, 2 means ignored error
    my @what;  # what features are needed

    # first, remove all lingering log files
    if(!cleardir($LOGDIR) && $clearlocks) {
        clearlocks($LOGDIR);
        cleardir($LOGDIR);
    }

    # timestamp test preparation start
    $timeprepini{$testnum} = Time::HiRes::time();

    if($disttests !~ /test$testnum(\W|\z)/ ) {
        logmsg "Warning: test$testnum not present in tests/data/Makefile.inc\n";
    }
    if($disabled{$testnum}) {
        if(!$run_disabled) {
            $why = "listed in DISABLED";
        }
        else {
            logmsg "Warning: test$testnum is explicitly disabled\n";
        }
    }
    if($ignored{$testnum}) {
        logmsg "Warning: test$testnum result is ignored\n";
        $errorreturncode = 2;
    }

    # load the test case file definition
    if(loadtest("${TESTDIR}/test${testnum}")) {
        if($verbose) {
            # this is not a test
            logmsg "RUN: $testnum doesn't look like a test case\n";
        }
        $why = "no test";
    }
    else {
        @what = getpart("client", "features");
    }

    # We require a feature to be present
    for(@what) {
        my $f = $_;
        $f =~ s/\s//g;

        if($f =~ /^([^!].*)$/) {
            if($feature{$1}) {
                next;
            }

            $why = "curl lacks $1 support";
            last;
        }
    }

    # We require a feature to not be present
    if(!$why) {
        for(@what) {
            my $f = $_;
            $f =~ s/\s//g;

            if($f =~ /^!(.*)$/) {
                if(!$feature{$1}) {
                    next;
                }
            }
            else {
                next;
            }

            $why = "curl has $1 support";
            last;
        }
    }

    my @info_keywords = getpart("info", "keywords");
    if(!$why) {
        my $match;

        # Clear the list of keywords from the last test
        %keywords = ();

        if(!$info_keywords[0]) {
            $why = "missing the <keywords> section!";
        }

        for my $k (@info_keywords) {
            chomp $k;
            if ($disabled_keywords{lc($k)}) {
                $why = "disabled by keyword";
            }
            elsif ($enabled_keywords{lc($k)}) {
                $match = 1;
            }
            if ($ignored_keywords{lc($k)}) {
                logmsg "Warning: test$testnum result is ignored due to $k\n";
                $errorreturncode = 2;
            }

            $keywords{$k} = 1;
        }

        if(!$why && !$match && %enabled_keywords) {
            $why = "disabled by missing keyword";
        }
    }

    if (!$why && defined $custom_skip_reasons{test}{$testnum}) {
        $why = $custom_skip_reasons{test}{$testnum};
    }

    if (!$why && defined $custom_skip_reasons{tool}) {
        foreach my $tool (getpart("client", "tool")) {
            foreach my $tool_skip_pattern (keys %{$custom_skip_reasons{tool}}) {
                if ($tool =~ /$tool_skip_pattern/i) {
                    $why = $custom_skip_reasons{tool}{$tool_skip_pattern};
                }
            }
        }
    }

    if (!$why && defined $custom_skip_reasons{keyword}) {
        foreach my $keyword (@info_keywords) {
            foreach my $keyword_skip_pattern (keys %{$custom_skip_reasons{keyword}}) {
                if ($keyword =~ /$keyword_skip_pattern/i) {
                    $why = $custom_skip_reasons{keyword}{$keyword_skip_pattern};
                }
            }
        }
    }

    return ($why, $errorreturncode);
}


#######################################################################
# Start the servers needed to run this test case
sub singletest_startservers {
    my ($testnum, $why) = @_;

    # remove test server commands file before servers are started/verified
    unlink($FTPDCMD) if(-f $FTPDCMD);

    # timestamp required servers verification start
    $timesrvrini{$testnum} = Time::HiRes::time();

    if (!$why && !$listonly) {
        my @what = getpart("client", "server");
        if(!$what[0]) {
            warn "Test case $testnum has no server(s) specified";
            $why = "no server specified";
        } else {
            my $err;
            ($why, $err) = serverfortest(@what);
            if($err == 1) {
                # Error indicates an actual problem starting the server, so
                # display the server logs
                displaylogs($testnum);
            }
        }
    }

    # timestamp required servers verification end
    $timesrvrend{$testnum} = Time::HiRes::time();

    # remove server output logfile after servers are started/verified
    unlink($SERVERIN);
    unlink($SERVER2IN);
    unlink($PROXYIN);

    return $why;
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
                        # print "Skipping LD_PRELOAD due to lack of OS support\n";
                        next;
                    }
                    if($feature{"debug"} || !$has_shared) {
                        # print "Skipping LD_PRELOAD due to no release shared build\n";
                        next;
                    }
                }
                $ENV{$var} = "$content";
                print "setenv $var = $content\n" if($verbose);
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
# Print the test name and count tests
sub singletest_count {
    my ($testnum, $why) = @_;

    if($why && !$listonly) {
        # there's a problem, count it as "skipped"
        $skipped{$why}++;
        $teststat[$testnum]=$why; # store reason for this test case

        if(!$short) {
            if($skipped{$why} <= 3) {
                # show only the first three skips for each reason
                logmsg sprintf("test %04d SKIPPED: $why\n", $testnum);
            }
        }

        timestampskippedevents($testnum);
        return ("Skipped", -1);
    }

    # At this point we've committed to run this test
    logmsg sprintf("test %04d...", $testnum) if(!$automakestyle);

    # name of the test
    my $testname= (getpart("client", "name"))[0];
    chomp $testname;
    logmsg "[$testname]\n" if(!$short);

    if($listonly) {
        timestampskippedevents($testnum);
    }
    return ("", 0);  # successful
}


#######################################################################
# Prepare the test environment to run this test case
sub singletest_prepare {
    my ($testnum, $why) = @_;

    if($feature{"TrackMemory"}) {
        unlink($memdump);
    }
    unlink("core");

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
                timestampskippedevents($testnum);
                return ("Syntax error", -1);
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
    return ($why, 0);
}


#######################################################################
# Run the test command
sub singletest_run {
    my $testnum = $_[0];

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
    my $CMDLINE;
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
            timestampskippedevents($testnum);
            return (-1, 0, 0, "", "", 0);
        }
        $DBGCURL=$CMDLINE;
    }

    if($fail_due_event_based) {
        logmsg "This test cannot run event based\n";
        timestampskippedevents($testnum);
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
    $timetoolini{$testnum} = Time::HiRes::time();

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
    $timetoolend{$testnum} = Time::HiRes::time();

    return (0, $cmdres, $dumped_core, $CURLOUT, $tool, $disablevalgrind);
}


#######################################################################
# Clean up after test command
sub singletest_clean {
    my ($testnum, $dumped_core)=@_;

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
    $timesrvrlog{$testnum} = Time::HiRes::time();

    # test definition might instruct to stop some servers
    # stop also all servers relative to the given one

    my @killtestservers = getpart("client", "killserver");
    if(@killtestservers) {
        foreach my $server (@killtestservers) {
            chomp $server;
            if(stopserver($server)) {
                return 1; # normal error if asked to fail on unexpected alive
            }
        }
    }
    return 0;
}


#######################################################################
# Verify test succeeded
sub singletest_check {
    my ($testnum, $cmdres, $CURLOUT, $tool, $disablevalgrind)=@_;

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
                # timestamp test result verification end
                $timevrfyend{$testnum} = Time::HiRes::time();
                return -1;
            }
        }
    }

    # restore environment variables that were modified
    restore_test_env(0);

    # Skip all the verification on torture tests
    if ($torture) {
        # timestamp test result verification end
        $timevrfyend{$testnum} = Time::HiRes::time();
        return -2;
    }

    my @err = getpart("verify", "errorcode");
    my $errorcode = $err[0] || "0";
    my $ok="";
    my $res;
    chomp $errorcode;
    my $testname= (getpart("client", "name"))[0];
    chomp $testname;
    # what parts to cut off from stdout/stderr
    my @stripfile = getpart("verify", "stripfile");

    my @validstdout = getpart("verify", "stdout");
    if (@validstdout) {
        # verify redirected stdout
        my @actual = loadarray($STDOUT);

        foreach my $strip (@stripfile) {
            chomp $strip;
            my @newgen;
            for(@actual) {
                eval $strip;
                if($_) {
                    push @newgen, $_;
                }
            }
            # this is to get rid of array entries that vanished (zero
            # length) because of replacements
            @actual = @newgen;
        }

        # get all attributes
        my %hash = getpartattr("verify", "stdout");

        # get the mode attribute
        my $filemode=$hash{'mode'};
        if($filemode && ($filemode eq "text") && $has_textaware) {
            # text mode when running on windows: fix line endings
            s/\r\n/\n/g for @validstdout;
            s/\n/\r\n/g for @validstdout;
        }

        if($hash{'nonewline'}) {
            # Yes, we must cut off the final newline from the final line
            # of the protocol data
            chomp($validstdout[-1]);
        }

        if($hash{'crlf'} ||
           ($feature{"hyper"} && ($keywords{"HTTP"}
                           || $keywords{"HTTPS"}))) {
            subNewlines(0, \$_) for @validstdout;
        }

        $res = compare($testnum, $testname, "stdout", \@actual, \@validstdout);
        if($res) {
            return -1;
        }
        $ok .= "s";
    }
    else {
        $ok .= "-"; # stdout not checked
    }

    my @validstderr = getpart("verify", "stderr");
    if (@validstderr) {
        # verify redirected stderr
        my @actual = loadarray($STDERR);

        foreach my $strip (@stripfile) {
            chomp $strip;
            my @newgen;
            for(@actual) {
                eval $strip;
                if($_) {
                    push @newgen, $_;
                }
            }
            # this is to get rid of array entries that vanished (zero
            # length) because of replacements
            @actual = @newgen;
        }

        # get all attributes
        my %hash = getpartattr("verify", "stderr");

        # get the mode attribute
        my $filemode=$hash{'mode'};
        if($filemode && ($filemode eq "text") && $feature{"hyper"}) {
            # text mode check in hyper-mode. Sometimes necessary if the stderr
            # data *looks* like HTTP and thus has gotten CRLF newlines
            # mistakenly
            s/\r\n/\n/g for @validstderr;
        }
        if($filemode && ($filemode eq "text") && $has_textaware) {
            # text mode when running on windows: fix line endings
            s/\r\n/\n/g for @validstderr;
            s/\n/\r\n/g for @validstderr;
        }

        if($hash{'nonewline'}) {
            # Yes, we must cut off the final newline from the final line
            # of the protocol data
            chomp($validstderr[-1]);
        }

        $res = compare($testnum, $testname, "stderr", \@actual, \@validstderr);
        if($res) {
            return -1;
        }
        $ok .= "r";
    }
    else {
        $ok .= "-"; # stderr not checked
    }

    # what to cut off from the live protocol sent by curl
    my @strip = getpart("verify", "strip");

    # what parts to cut off from the protocol & upload
    my @strippart = getpart("verify", "strippart");

    # this is the valid protocol blurb curl should generate
    my @protocol= getpart("verify", "protocol");
    if(@protocol) {
        # Verify the sent request
        my @out = loadarray($SERVERIN);

        # check if there's any attributes on the verify/protocol section
        my %hash = getpartattr("verify", "protocol");

        if($hash{'nonewline'}) {
            # Yes, we must cut off the final newline from the final line
            # of the protocol data
            chomp($protocol[-1]);
        }

        for(@strip) {
            # strip off all lines that match the patterns from both arrays
            chomp $_;
            @out = striparray( $_, \@out);
            @protocol= striparray( $_, \@protocol);
        }

        for my $strip (@strippart) {
            chomp $strip;
            for(@out) {
                eval $strip;
            }
        }

        if($hash{'crlf'}) {
            subNewlines(1, \$_) for @protocol;
        }

        if((!$out[0] || ($out[0] eq "")) && $protocol[0]) {
            logmsg "\n $testnum: protocol FAILED!\n".
                " There was no content at all in the file $SERVERIN.\n".
                " Server glitch? Total curl failure? Returned: $cmdres\n";
            # timestamp test result verification end
            $timevrfyend{$testnum} = Time::HiRes::time();
            return -1;
        }

        $res = compare($testnum, $testname, "protocol", \@out, \@protocol);
        if($res) {
            return -1;
        }

        $ok .= "p";

    }
    else {
        $ok .= "-"; # protocol not checked
    }

    my %replyattr = getpartattr("reply", "data");
    my @reply;
    if (partexists("reply", "datacheck")) {
        for my $partsuffix (('', '1', '2', '3', '4')) {
            my @replycheckpart = getpart("reply", "datacheck".$partsuffix);
            if(@replycheckpart) {
                my %replycheckpartattr = getpartattr("reply", "datacheck".$partsuffix);
                # get the mode attribute
                my $filemode=$replycheckpartattr{'mode'};
                if($filemode && ($filemode eq "text") && $has_textaware) {
                    # text mode when running on windows: fix line endings
                    s/\r\n/\n/g for @replycheckpart;
                    s/\n/\r\n/g for @replycheckpart;
                }
                if($replycheckpartattr{'nonewline'}) {
                    # Yes, we must cut off the final newline from the final line
                    # of the datacheck
                    chomp($replycheckpart[-1]);
                }
                if($replycheckpartattr{'crlf'} ||
                   ($feature{"hyper"} && ($keywords{"HTTP"}
                                   || $keywords{"HTTPS"}))) {
                    subNewlines(0, \$_) for @replycheckpart;
                }
                push(@reply, @replycheckpart);
            }
        }
    }
    else {
        # check against the data section
        @reply = getpart("reply", "data");
        if(@reply) {
            if($replyattr{'nonewline'}) {
                # cut off the final newline from the final line of the data
                chomp($reply[-1]);
            }
        }
        # get the mode attribute
        my $filemode=$replyattr{'mode'};
        if($filemode && ($filemode eq "text") && $has_textaware) {
            # text mode when running on windows: fix line endings
            s/\r\n/\n/g for @reply;
            s/\n/\r\n/g for @reply;
        }
        if($replyattr{'crlf'} ||
           ($feature{"hyper"} && ($keywords{"HTTP"}
                           || $keywords{"HTTPS"}))) {
            subNewlines(0, \$_) for @reply;
        }
    }

    if(!$replyattr{'nocheck'} && (@reply || $replyattr{'sendzero'})) {
        # verify the received data
        my @out = loadarray($CURLOUT);
        $res = compare($testnum, $testname, "data", \@out, \@reply);
        if ($res) {
            return -1;
        }
        $ok .= "d";
    }
    else {
        $ok .= "-"; # data not checked
    }

    # if this section exists, we verify upload
    my @upload = getpart("verify", "upload");
    if(@upload) {
        my %hash = getpartattr("verify", "upload");
        if($hash{'nonewline'}) {
            # cut off the final newline from the final line of the upload data
            chomp($upload[-1]);
        }

        # verify uploaded data
        my @out = loadarray("$LOGDIR/upload.$testnum");
        for my $strip (@strippart) {
            chomp $strip;
            for(@out) {
                eval $strip;
            }
        }

        $res = compare($testnum, $testname, "upload", \@out, \@upload);
        if ($res) {
            return -1;
        }
        $ok .= "u";
    }
    else {
        $ok .= "-"; # upload not checked
    }

    # this is the valid protocol blurb curl should generate to a proxy
    my @proxyprot = getpart("verify", "proxy");
    if(@proxyprot) {
        # Verify the sent proxy request
        # check if there's any attributes on the verify/protocol section
        my %hash = getpartattr("verify", "proxy");

        if($hash{'nonewline'}) {
            # Yes, we must cut off the final newline from the final line
            # of the protocol data
            chomp($proxyprot[-1]);
        }

        my @out = loadarray($PROXYIN);
        for(@strip) {
            # strip off all lines that match the patterns from both arrays
            chomp $_;
            @out = striparray( $_, \@out);
            @proxyprot= striparray( $_, \@proxyprot);
        }

        for my $strip (@strippart) {
            chomp $strip;
            for(@out) {
                eval $strip;
            }
        }

        if($hash{'crlf'} ||
           ($feature{"hyper"} && ($keywords{"HTTP"} || $keywords{"HTTPS"}))) {
            subNewlines(0, \$_) for @proxyprot;
        }

        $res = compare($testnum, $testname, "proxy", \@out, \@proxyprot);
        if($res) {
            return -1;
        }

        $ok .= "P";

    }
    else {
        $ok .= "-"; # protocol not checked
    }

    my $outputok;
    for my $partsuffix (('', '1', '2', '3', '4')) {
        my @outfile=getpart("verify", "file".$partsuffix);
        if(@outfile || partexists("verify", "file".$partsuffix) ) {
            # we're supposed to verify a dynamically generated file!
            my %hash = getpartattr("verify", "file".$partsuffix);

            my $filename=$hash{'name'};
            if(!$filename) {
                logmsg "ERROR: section verify=>file$partsuffix ".
                       "has no name attribute\n";
                stopservers($verbose);
                # timestamp test result verification end
                $timevrfyend{$testnum} = Time::HiRes::time();
                return -1;
            }
            my @generated=loadarray($filename);

            # what parts to cut off from the file
            my @stripfilepar = getpart("verify", "stripfile".$partsuffix);

            my $filemode=$hash{'mode'};
            if($filemode && ($filemode eq "text") && $has_textaware) {
                # text mode when running on windows: fix line endings
                s/\r\n/\n/g for @outfile;
                s/\n/\r\n/g for @outfile;
            }
            if($hash{'crlf'} ||
               ($feature{"hyper"} && ($keywords{"HTTP"}
                               || $keywords{"HTTPS"}))) {
                subNewlines(0, \$_) for @outfile;
            }

            for my $strip (@stripfilepar) {
                chomp $strip;
                my @newgen;
                for(@generated) {
                    eval $strip;
                    if($_) {
                        push @newgen, $_;
                    }
                }
                # this is to get rid of array entries that vanished (zero
                # length) because of replacements
                @generated = @newgen;
            }

            $res = compare($testnum, $testname, "output ($filename)",
                           \@generated, \@outfile);
            if($res) {
                return -1;
            }

            $outputok = 1; # output checked
        }
    }
    $ok .= ($outputok) ? "o" : "-"; # output checked or not

    # verify SOCKS proxy details
    my @socksprot = getpart("verify", "socks");
    if(@socksprot) {
        # Verify the sent SOCKS proxy details
        my @out = loadarray($SOCKSIN);
        $res = compare($testnum, $testname, "socks", \@out, \@socksprot);
        if($res) {
            return -1;
        }
    }

    # accept multiple comma-separated error codes
    my @splerr = split(/ *, */, $errorcode);
    my $errok;
    foreach my $e (@splerr) {
        if($e == $cmdres) {
            # a fine error code
            $errok = 1;
            last;
        }
    }

    if($errok) {
        $ok .= "e";
    }
    else {
        if(!$short) {
            logmsg sprintf("\n%s returned $cmdres, when expecting %s\n",
                           (!$tool)?"curl":$tool, $errorcode);
        }
        logmsg " exit FAILED\n";
        # timestamp test result verification end
        $timevrfyend{$testnum} = Time::HiRes::time();
        return -1;
    }

    if($feature{"TrackMemory"}) {
        if(! -f $memdump) {
            my %cmdhash = getpartattr("client", "command");
            my $cmdtype = $cmdhash{'type'} || "default";
            logmsg "\n** ALERT! memory tracking with no output file?\n"
                if(!$cmdtype eq "perl");
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
                logmsg "\n** MEMORY FAILURE\n";
                logmsg @memdata;
                # timestamp test result verification end
                $timevrfyend{$testnum} = Time::HiRes::time();
                return -1;
            }
            else {
                $ok .= "m";
            }
        }
    }
    else {
        $ok .= "-"; # memory not checked
    }

    if($valgrind) {
        if(use_valgrind() && !$disablevalgrind) {
            if(!opendir(DIR, "$LOGDIR")) {
                logmsg "ERROR: unable to read $LOGDIR\n";
                # timestamp test result verification end
                $timevrfyend{$testnum} = Time::HiRes::time();
                return -1;
            }
            my @files = readdir(DIR);
            closedir(DIR);
            my $vgfile;
            foreach my $file (@files) {
                if($file =~ /^valgrind$testnum(\..*|)$/) {
                    $vgfile = $file;
                    last;
                }
            }
            if(!$vgfile) {
                logmsg "ERROR: valgrind log file missing for test $testnum\n";
                # timestamp test result verification end
                $timevrfyend{$testnum} = Time::HiRes::time();
                return -1;
            }
            my @e = valgrindparse("$LOGDIR/$vgfile");
            if(@e && $e[0]) {
                if($automakestyle) {
                    logmsg "FAIL: $testnum - $testname - valgrind\n";
                }
                else {
                    logmsg " valgrind ERROR ";
                    logmsg @e;
                }
                # timestamp test result verification end
                $timevrfyend{$testnum} = Time::HiRes::time();
                return -1;
            }
            $ok .= "v";
        }
        else {
            if($verbose && !$disablevalgrind) {
                logmsg " valgrind SKIPPED\n";
            }
            $ok .= "-"; # skipped
        }
    }
    else {
        $ok .= "-"; # valgrind not checked
    }
    # add 'E' for event-based
    $ok .= $run_event_based ? "E" : "-";

    logmsg "$ok " if(!$short);

    # timestamp test result verification end
    $timevrfyend{$testnum} = Time::HiRes::time();

    return 0;
}


#######################################################################
# Report a successful test
sub singletest_success {
    my ($testnum, $count, $total, $errorreturncode)=@_;

    my $sofar= time()-$start;
    my $esttotal = $sofar/$count * $total;
    my $estleft = $esttotal - $sofar;
    my $timeleft=sprintf("remaining: %02d:%02d",
                     $estleft/60,
                     $estleft%60);
    my $took = $timevrfyend{$testnum} - $timeprepini{$testnum};
    my $duration = sprintf("duration: %02d:%02d",
                           $sofar/60, $sofar%60);
    if(!$automakestyle) {
        logmsg sprintf("OK (%-3d out of %-3d, %s, took %.3fs, %s)\n",
                       $count, $total, $timeleft, $took, $duration);
    }
    else {
        my $testname= (getpart("client", "name"))[0];
        chomp $testname;
        logmsg "PASS: $testnum - $testname\n";
    }

    if($errorreturncode==2) {
        logmsg "Warning: test$testnum result is ignored, but passed!\n";
    }
}


#######################################################################
# Run a single specified test case
#
sub singletest {
    my ($testnum, $count, $total)=@_;

    #######################################################################
    # Verify that the test should be run
    my ($why, $errorreturncode) = singletest_shouldrun($testnum);


    #######################################################################
    # Restore environment variables that were modified in a previous run.
    # Test definition may instruct to (un)set environment vars.
    # This is done this early so that leftover variables don't affect starting
    # servers.
    restore_test_env(1);


    #######################################################################
    # Register the test case with the CI environment
    citest_starttest($testnum);


    #######################################################################
    # Start the servers needed to run this test case
    $why = singletest_startservers($testnum, $why);


    #######################################################################
    # Generate preprocessed test file
    singletest_preprocess($testnum);


    #######################################################################
    # Set up the test environment to run this test case
    singletest_setenv();


    #######################################################################
    # Check that the test environment is fine to run this test case
    if (!$why && !$listonly) {
        $why = singletest_precheck($testnum);
    }


    #######################################################################
    # Print the test name and count tests
    my $error;
    ($why, $error) = singletest_count($testnum, $why);
    if($error || $listonly) {
        return $error;
    }


    #######################################################################
    # Prepare the test environment to run this test case
    ($why, $error) = singletest_prepare($testnum, $why);
    if($error) {
        return $error;
    }


    #######################################################################
    # Run the test command
    my $cmdres;
    my $dumped_core;
    my $CURLOUT;
    my $tool;
    my $disablevalgrind;
    ($error, $cmdres, $dumped_core, $CURLOUT, $tool, $disablevalgrind) = singletest_run($testnum);
    if($error) {
        return $error;
    }


    #######################################################################
    # Clean up after test command
    $error = singletest_clean($testnum, $dumped_core);
    if($error) {
        return $error;
    }


    #######################################################################
    # Verify that the test succeeded
    $error = singletest_check($testnum, $cmdres, $CURLOUT, $tool, $disablevalgrind);
    if($error == -1) {
      # return a test failure, either to be reported or to be ignored
      return $errorreturncode;
    }
    elsif($error == -2) {
      # torture test; there is no verification, so the run result holds the
      # test success code
      return $cmdres;
    }

    #######################################################################
    # Report a successful test
    singletest_success($testnum, $count, $total, $errorreturncode);


    return 0;
}

#######################################################################
# runtimestats displays test-suite run time statistics
#
sub runtimestats {
    my $lasttest = $_[0];

    return if(not $timestats);

    logmsg "\nTest suite total running time breakdown per task...\n\n";

    my @timesrvr;
    my @timeprep;
    my @timetool;
    my @timelock;
    my @timevrfy;
    my @timetest;
    my $timesrvrtot = 0.0;
    my $timepreptot = 0.0;
    my $timetooltot = 0.0;
    my $timelocktot = 0.0;
    my $timevrfytot = 0.0;
    my $timetesttot = 0.0;
    my $counter;

    for my $testnum (1 .. $lasttest) {
        if($timesrvrini{$testnum}) {
            $timesrvrtot += $timesrvrend{$testnum} - $timesrvrini{$testnum};
            $timepreptot +=
                (($timetoolini{$testnum} - $timeprepini{$testnum}) -
                 ($timesrvrend{$testnum} - $timesrvrini{$testnum}));
            $timetooltot += $timetoolend{$testnum} - $timetoolini{$testnum};
            $timelocktot += $timesrvrlog{$testnum} - $timetoolend{$testnum};
            $timevrfytot += $timevrfyend{$testnum} - $timesrvrlog{$testnum};
            $timetesttot += $timevrfyend{$testnum} - $timeprepini{$testnum};
            push @timesrvr, sprintf("%06.3f  %04d",
                $timesrvrend{$testnum} - $timesrvrini{$testnum}, $testnum);
            push @timeprep, sprintf("%06.3f  %04d",
                ($timetoolini{$testnum} - $timeprepini{$testnum}) -
                ($timesrvrend{$testnum} - $timesrvrini{$testnum}), $testnum);
            push @timetool, sprintf("%06.3f  %04d",
                $timetoolend{$testnum} - $timetoolini{$testnum}, $testnum);
            push @timelock, sprintf("%06.3f  %04d",
                $timesrvrlog{$testnum} - $timetoolend{$testnum}, $testnum);
            push @timevrfy, sprintf("%06.3f  %04d",
                $timevrfyend{$testnum} - $timesrvrlog{$testnum}, $testnum);
            push @timetest, sprintf("%06.3f  %04d",
                $timevrfyend{$testnum} - $timeprepini{$testnum}, $testnum);
        }
    }

    {
        no warnings 'numeric';
        @timesrvr = sort { $b <=> $a } @timesrvr;
        @timeprep = sort { $b <=> $a } @timeprep;
        @timetool = sort { $b <=> $a } @timetool;
        @timelock = sort { $b <=> $a } @timelock;
        @timevrfy = sort { $b <=> $a } @timevrfy;
        @timetest = sort { $b <=> $a } @timetest;
    }

    logmsg "Spent ". sprintf("%08.3f ", $timesrvrtot) .
           "seconds starting and verifying test harness servers.\n";
    logmsg "Spent ". sprintf("%08.3f ", $timepreptot) .
           "seconds reading definitions and doing test preparations.\n";
    logmsg "Spent ". sprintf("%08.3f ", $timetooltot) .
           "seconds actually running test tools.\n";
    logmsg "Spent ". sprintf("%08.3f ", $timelocktot) .
           "seconds awaiting server logs lock removal.\n";
    logmsg "Spent ". sprintf("%08.3f ", $timevrfytot) .
           "seconds verifying test results.\n";
    logmsg "Spent ". sprintf("%08.3f ", $timetesttot) .
           "seconds doing all of the above.\n";

    $counter = 25;
    logmsg "\nTest server starting and verification time per test ".
        sprintf("(%s)...\n\n", (not $fullstats)?"top $counter":"full");
    logmsg "-time-  test\n";
    logmsg "------  ----\n";
    foreach my $txt (@timesrvr) {
        last if((not $fullstats) && (not $counter--));
        logmsg "$txt\n";
    }

    $counter = 10;
    logmsg "\nTest definition reading and preparation time per test ".
        sprintf("(%s)...\n\n", (not $fullstats)?"top $counter":"full");
    logmsg "-time-  test\n";
    logmsg "------  ----\n";
    foreach my $txt (@timeprep) {
        last if((not $fullstats) && (not $counter--));
        logmsg "$txt\n";
    }

    $counter = 25;
    logmsg "\nTest tool execution time per test ".
        sprintf("(%s)...\n\n", (not $fullstats)?"top $counter":"full");
    logmsg "-time-  test\n";
    logmsg "------  ----\n";
    foreach my $txt (@timetool) {
        last if((not $fullstats) && (not $counter--));
        logmsg "$txt\n";
    }

    $counter = 15;
    logmsg "\nTest server logs lock removal time per test ".
        sprintf("(%s)...\n\n", (not $fullstats)?"top $counter":"full");
    logmsg "-time-  test\n";
    logmsg "------  ----\n";
    foreach my $txt (@timelock) {
        last if((not $fullstats) && (not $counter--));
        logmsg "$txt\n";
    }

    $counter = 10;
    logmsg "\nTest results verification time per test ".
        sprintf("(%s)...\n\n", (not $fullstats)?"top $counter":"full");
    logmsg "-time-  test\n";
    logmsg "------  ----\n";
    foreach my $txt (@timevrfy) {
        last if((not $fullstats) && (not $counter--));
        logmsg "$txt\n";
    }

    $counter = 50;
    logmsg "\nTotal time per test ".
        sprintf("(%s)...\n\n", (not $fullstats)?"top $counter":"full");
    logmsg "-time-  test\n";
    logmsg "------  ----\n";
    foreach my $txt (@timetest) {
        last if((not $fullstats) && (not $counter--));
        logmsg "$txt\n";
    }

    logmsg "\n";
}

#######################################################################
# Check options to this test program
#

# Special case for CMake: replace '$TFLAGS' by the contents of the
# environment variable (if any).
if(@ARGV && $ARGV[-1] eq '$TFLAGS') {
    pop @ARGV;
    push(@ARGV, split(' ', $ENV{'TFLAGS'})) if defined($ENV{'TFLAGS'});
}

my $number=0;
my $fromnum=-1;
my @testthis;
while(@ARGV) {
    if ($ARGV[0] eq "-v") {
        # verbose output
        $verbose=1;
    }
    elsif ($ARGV[0] eq "-c") {
        # use this path to curl instead of default
        $DBGCURL=$CURL="\"$ARGV[1]\"";
        shift @ARGV;
    }
    elsif ($ARGV[0] eq "-vc") {
        # use this path to a curl used to verify servers

        # Particularly useful when you introduce a crashing bug somewhere in
        # the development version as then it won't be able to run any tests
        # since it can't verify the servers!

        $VCURL="\"$ARGV[1]\"";
        shift @ARGV;
    }
    elsif ($ARGV[0] eq "-ac") {
        # use this curl only to talk to APIs (currently only CI test APIs)
        $ACURL="\"$ARGV[1]\"";
        shift @ARGV;
    }
    elsif ($ARGV[0] eq "-d") {
        # have the servers display protocol output
        $debugprotocol=1;
    }
    elsif($ARGV[0] eq "-e") {
        # run the tests cases event based if possible
        $run_event_based=1;
    }
    elsif($ARGV[0] eq "-f") {
        # force - run the test case even if listed in DISABLED
        $run_disabled=1;
    }
    elsif($ARGV[0] eq "-E") {
        # load additional reasons to skip tests
        shift @ARGV;
        my $exclude_file = $ARGV[0];
        open(my $fd, "<", $exclude_file) or die "Couldn't open '$exclude_file': $!";
        while(my $line = <$fd>) {
            next if ($line =~ /^#/);
            chomp $line;
            my ($type, $patterns, $skip_reason) = split(/\s*:\s*/, $line, 3);

            die "Unsupported type: $type\n" if($type !~ /^keyword|test|tool$/);

            foreach my $pattern (split(/,/, $patterns)) {
                if($type eq "test") {
                    # Strip leading zeros in the test number
                    $pattern = int($pattern);
                }
                $custom_skip_reasons{$type}{$pattern} = $skip_reason;
            }
        }
        close($fd);
    }
    elsif ($ARGV[0] eq "-g") {
        # run this test with gdb
        $gdbthis=1;
    }
    elsif ($ARGV[0] eq "-gw") {
        # run this test with windowed gdb
        $gdbthis=1;
        $gdbxwin=1;
    }
    elsif($ARGV[0] eq "-s") {
        # short output
        $short=1;
    }
    elsif($ARGV[0] eq "-am") {
        # automake-style output
        $short=1;
        $automakestyle=1;
    }
    elsif($ARGV[0] eq "-n") {
        # no valgrind
        undef $valgrind;
    }
    elsif($ARGV[0] eq "--no-debuginfod") {
        # disable the valgrind debuginfod functionality
        $no_debuginfod = 1;
    }
    elsif ($ARGV[0] eq "-R") {
        # execute in scrambled order
        $scrambleorder=1;
    }
    elsif($ARGV[0] =~ /^-t(.*)/) {
        # torture
        $torture=1;
        my $xtra = $1;

        if($xtra =~ s/(\d+)$//) {
            $tortalloc = $1;
        }
    }
    elsif($ARGV[0] =~ /--shallow=(\d+)/) {
        # Fail no more than this amount per tests when running
        # torture.
        my ($num)=($1);
        $shallow=$num;
    }
    elsif($ARGV[0] =~ /--repeat=(\d+)/) {
        # Repeat-run the given tests this many times
        $repeat = $1;
    }
    elsif($ARGV[0] =~ /--seed=(\d+)/) {
        # Set a fixed random seed (used for -R and --shallow)
        $randseed = $1;
    }
    elsif($ARGV[0] eq "-a") {
        # continue anyway, even if a test fail
        $anyway=1;
    }
    elsif($ARGV[0] eq "-o") {
        shift @ARGV;
        if ($ARGV[0] =~ /^(\w+)=([\w.:\/\[\]-]+)$/) {
            my ($variable, $value) = ($1, $2);
            eval "\$$variable='$value'" or die "Failed to set \$$variable to $value: $@";
        } else {
            die "Failed to parse '-o $ARGV[0]'. May contain unexpected characters.\n";
        }
    }
    elsif($ARGV[0] eq "-p") {
        $postmortem=1;
    }
    elsif($ARGV[0] eq "-P") {
        shift @ARGV;
        $proxy_address=$ARGV[0];
    }
    elsif($ARGV[0] eq "-L") {
        # require additional library file
        shift @ARGV;
        require $ARGV[0];
    }
    elsif($ARGV[0] eq "-l") {
        # lists the test case names only
        $listonly=1;
    }
    elsif($ARGV[0] eq "-k") {
        # keep stdout and stderr files after tests
        $keepoutfiles=1;
    }
    elsif($ARGV[0] eq "-r") {
        # run time statistics needs Time::HiRes
        if($Time::HiRes::VERSION) {
            keys(%timeprepini) = 1000;
            keys(%timesrvrini) = 1000;
            keys(%timesrvrend) = 1000;
            keys(%timetoolini) = 1000;
            keys(%timetoolend) = 1000;
            keys(%timesrvrlog) = 1000;
            keys(%timevrfyend) = 1000;
            $timestats=1;
            $fullstats=0;
        }
    }
    elsif($ARGV[0] eq "-rf") {
        # run time statistics needs Time::HiRes
        if($Time::HiRes::VERSION) {
            keys(%timeprepini) = 1000;
            keys(%timesrvrini) = 1000;
            keys(%timesrvrend) = 1000;
            keys(%timetoolini) = 1000;
            keys(%timetoolend) = 1000;
            keys(%timesrvrlog) = 1000;
            keys(%timevrfyend) = 1000;
            $timestats=1;
            $fullstats=1;
        }
    }
    elsif($ARGV[0] eq "-rm") {
        # force removal of files by killing locking processes
        $clearlocks=1;
    }
    elsif($ARGV[0] eq "-u") {
        # error instead of warning on server unexpectedly alive
        $err_unexpected=1;
    }
    elsif(($ARGV[0] eq "-h") || ($ARGV[0] eq "--help")) {
        # show help text
        print <<"EOHELP"
Usage: runtests.pl [options] [test selection(s)]
  -a       continue even if a test fails
  -ac path use this curl only to talk to APIs (currently only CI test APIs)
  -am      automake style output PASS/FAIL: [number] [name]
  -c path  use this curl executable
  -d       display server debug info
  -e       event-based execution
  -E file  load the specified file to exclude certain tests
  -f       forcibly run even if disabled
  -g       run the test case with gdb
  -gw      run the test case with gdb as a windowed application
  -h       this help text
  -k       keep stdout and stderr files present after tests
  -L path  require an additional perl library file to replace certain functions
  -l       list all test case names/descriptions
  -n       no valgrind
  --no-debuginfod disable the valgrind debuginfod functionality
  -o variable=value set internal variable to the specified value
  -P proxy use the specified proxy
  -p       print log file contents when a test fails
  -R       scrambled order (uses the random seed, see --seed)
  -r       run time statistics
  -rf      full run time statistics
  -rm      force removal of files by killing locking processes (Windows only)
  --repeat=[num] run the given tests this many times
  -s       short output
  --seed=[num] set the random seed to a fixed number
  --shallow=[num] randomly makes the torture tests "thinner"
  -t[N]    torture (simulate function failures); N means fail Nth function
  -u       error instead of warning on server unexpectedly alive
  -v       verbose output
  -vc path use this curl only to verify the existing servers
  [num]    like "5 6 9" or " 5 to 22 " to run those tests only
  [!num]   like "!5 !6 !9" to disable those tests
  [~num]   like "~5 ~6 ~9" to ignore the result of those tests
  [keyword] like "IPv6" to select only tests containing the key word
  [!keyword] like "!cookies" to disable any tests containing the key word
  [~keyword] like "~cookies" to ignore results of tests containing key word
EOHELP
    ;
        exit;
    }
    elsif($ARGV[0] =~ /^(\d+)/) {
        $number = $1;
        if($fromnum >= 0) {
            for my $n ($fromnum .. $number) {
                push @testthis, $n;
            }
            $fromnum = -1;
        }
        else {
            push @testthis, $1;
        }
    }
    elsif($ARGV[0] =~ /^to$/i) {
        $fromnum = $number+1;
    }
    elsif($ARGV[0] =~ /^!(\d+)/) {
        $fromnum = -1;
        $disabled{$1}=$1;
    }
    elsif($ARGV[0] =~ /^~(\d+)/) {
        $fromnum = -1;
        $ignored{$1}=$1;
    }
    elsif($ARGV[0] =~ /^!(.+)/) {
        $disabled_keywords{lc($1)}=$1;
    }
    elsif($ARGV[0] =~ /^~(.+)/) {
        $ignored_keywords{lc($1)}=$1;
    }
    elsif($ARGV[0] =~ /^([-[{a-zA-Z].*)/) {
        $enabled_keywords{lc($1)}=$1;
    }
    else {
        print "Unknown option: $ARGV[0]\n";
        exit;
    }
    shift @ARGV;
}

delete $ENV{'DEBUGINFOD_URLS'} if($ENV{'DEBUGINFOD_URLS'} && $no_debuginfod);

if(!$randseed) {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
        localtime(time);
    # seed of the month. December 2019 becomes 201912
    $randseed = ($year+1900)*100 + $mon+1;
    open(my $curlvh, "-|", "$CURL --version 2>/dev/null") ||
        die "could not get curl version!";
    my @c = <$curlvh>;
    close($curlvh) || die "could not get curl version!";
    # use the first line of output and get the md5 out of it
    my $str = md5($c[0]);
    $randseed += unpack('S', $str);  # unsigned 16 bit value
}
srand $randseed;

if(@testthis && ($testthis[0] ne "")) {
    $TESTCASES=join(" ", @testthis);
}

if($valgrind) {
    # we have found valgrind on the host, use it

    # verify that we can invoke it fine
    my $code = runclient("valgrind >/dev/null 2>&1");

    if(($code>>8) != 1) {
        #logmsg "Valgrind failure, disable it\n";
        undef $valgrind;
    } else {

        # since valgrind 2.1.x, '--tool' option is mandatory
        # use it, if it is supported by the version installed on the system
        runclient("valgrind --help 2>&1 | grep -- --tool > /dev/null 2>&1");
        if (($? >> 8)==0) {
            $valgrind_tool="--tool=memcheck";
        }
        open(my $curlh, "<", "$CURL");
        my $l = <$curlh>;
        if($l =~ /^\#\!/) {
            # A shell script. This is typically when built with libtool,
            $valgrind="../libtool --mode=execute $valgrind";
        }
        close($curlh);

        # valgrind 3 renamed the --logfile option to --log-file!!!
        my $ver=join(' ', runclientoutput("valgrind --version"));
        # cut off all but digits and dots
        $ver =~ s/[^0-9.]//g;

        if($ver =~ /^(\d+)/) {
            $ver = $1;
            if($ver >= 3) {
                $valgrind_logfile="--log-file";
            }
        }
    }
}

if ($gdbthis) {
    # open the executable curl and read the first 4 bytes of it
    open(my $check, "<", "$CURL");
    my $c;
    sysread $check, $c, 4;
    close($check);
    if($c eq "#! /") {
        # A shell script. This is typically when built with libtool,
        $libtool = 1;
        $gdb = "../libtool --mode=execute gdb";
    }
}

#######################################################################
# clear and create logging directory:
#

cleardir($LOGDIR);
mkdir($LOGDIR, 0777);
mkdir($PIDDIR, 0777);

#######################################################################
# initialize some variables
#

get_disttests();

#######################################################################
# Output curl version and host info being tested
#

if(!$listonly) {
    unlink($memdump);  # remove this if there was one left
    checksystemfeatures();
}

#######################################################################
# initialize configuration needed to set up servers
#
initserverconfig();

if(!$listonly) {
    # these can only be displayed after initserverconfig() has been called
    displayserverfeatures();

    # globally disabled tests
    disabledtests("$TESTDIR/DISABLED");
}

#######################################################################
# Fetch all disabled tests, if there are any
#

sub disabledtests {
    my ($file) = @_;
    my @input;

    if(open(my $disabledh, "<", "$file")) {
        while(<$disabledh>) {
            if(/^ *\#/) {
                # allow comments
                next;
            }
            push @input, $_;
        }
        close($disabledh);

        # preprocess the input to make conditionally disabled tests depending
        # on variables
        my @pp = prepro(0, @input);
        for my $t (@pp) {
            if($t =~ /(\d+)/) {
                my ($n) = $1;
                $disabled{$n}=$n; # disable this test number
                if(! -f "$srcdir/data/test$n") {
                    print STDERR "WARNING! Non-existing test $n in $file!\n";
                    # fail hard to make user notice
                    exit 1;
                }
                logmsg "DISABLED: test $n\n" if ($verbose);
            }
            else {
                print STDERR "$file: rubbish content: $t\n";
                exit 2;
            }
        }
    }
}

#######################################################################
# If 'all' tests are requested, find out all test numbers
#

if ( $TESTCASES eq "all") {
    # Get all commands and find out their test numbers
    opendir(DIR, $TESTDIR) || die "can't opendir $TESTDIR: $!";
    my @cmds = grep { /^test([0-9]+)$/ && -f "$TESTDIR/$_" } readdir(DIR);
    closedir(DIR);

    $TESTCASES=""; # start with no test cases

    # cut off everything but the digits
    for(@cmds) {
        $_ =~ s/[a-z\/\.]*//g;
    }
    # sort the numbers from low to high
    foreach my $n (sort { $a <=> $b } @cmds) {
        if($disabled{$n}) {
            # skip disabled test cases
            my $why = "configured as DISABLED";
            $skipped{$why}++;
            $teststat[$n]=$why; # store reason for this test case
            next;
        }
        $TESTCASES .= " $n";
    }
}
else {
    my $verified="";
    for(split(" ", $TESTCASES)) {
        if (-e "$TESTDIR/test$_") {
            $verified.="$_ ";
        }
    }
    if($verified eq "") {
        print "No existing test cases were specified\n";
        exit;
    }
    $TESTCASES = $verified;
}
if($repeat) {
    my $s;
    for(1 .. $repeat) {
        $s .= $TESTCASES;
    }
    $TESTCASES = $s;
}

if($scrambleorder) {
    # scramble the order of the test cases
    my @rand;
    while($TESTCASES) {
        my @all = split(/ +/, $TESTCASES);
        if(!$all[0]) {
            # if the first is blank, shift away it
            shift @all;
        }
        my $r = rand @all;
        push @rand, $all[$r];
        $all[$r]="";
        $TESTCASES = join(" ", @all);
    }
    $TESTCASES = join(" ", @rand);
}

# Display the contents of the given file.  Line endings are canonicalized
# and excessively long files are elided
sub displaylogcontent {
    my ($file)=@_;
    if(open(my $single, "<", "$file")) {
        my $linecount = 0;
        my $truncate;
        my @tail;
        while(my $string = <$single>) {
            $string =~ s/\r\n/\n/g;
            $string =~ s/[\r\f\032]/\n/g;
            $string .= "\n" unless ($string =~ /\n$/);
            $string =~ tr/\n//;
            for my $line (split(m/\n/, $string)) {
                $line =~ s/\s*\!$//;
                if ($truncate) {
                    push @tail, " $line\n";
                } else {
                    logmsg " $line\n";
                }
                $linecount++;
                $truncate = $linecount > 1000;
            }
        }
        close($single);
        if(@tail) {
            my $tailshow = 200;
            my $tailskip = 0;
            my $tailtotal = scalar @tail;
            if($tailtotal > $tailshow) {
                $tailskip = $tailtotal - $tailshow;
                logmsg "=== File too long: $tailskip lines omitted here\n";
            }
            for($tailskip .. $tailtotal-1) {
                logmsg "$tail[$_]";
            }
        }
    }
}

sub displaylogs {
    my ($testnum)=@_;
    opendir(DIR, "$LOGDIR") ||
        die "can't open dir: $!";
    my @logs = readdir(DIR);
    closedir(DIR);

    logmsg "== Contents of files in the $LOGDIR/ dir after test $testnum\n";
    foreach my $log (sort @logs) {
        if($log =~ /\.(\.|)$/) {
            next; # skip "." and ".."
        }
        if($log =~ /^\.nfs/) {
            next; # skip ".nfs"
        }
        if(($log eq "memdump") || ($log eq "core")) {
            next; # skip "memdump" and  "core"
        }
        if((-d "$LOGDIR/$log") || (! -s "$LOGDIR/$log")) {
            next; # skip directory and empty files
        }
        if(($log =~ /^stdout\d+/) && ($log !~ /^stdout$testnum/)) {
            next; # skip stdoutNnn of other tests
        }
        if(($log =~ /^stderr\d+/) && ($log !~ /^stderr$testnum/)) {
            next; # skip stderrNnn of other tests
        }
        if(($log =~ /^upload\d+/) && ($log !~ /^upload$testnum/)) {
            next; # skip uploadNnn of other tests
        }
        if(($log =~ /^curl\d+\.out/) && ($log !~ /^curl$testnum\.out/)) {
            next; # skip curlNnn.out of other tests
        }
        if(($log =~ /^test\d+\.txt/) && ($log !~ /^test$testnum\.txt/)) {
            next; # skip testNnn.txt of other tests
        }
        if(($log =~ /^file\d+\.txt/) && ($log !~ /^file$testnum\.txt/)) {
            next; # skip fileNnn.txt of other tests
        }
        if(($log =~ /^netrc\d+/) && ($log !~ /^netrc$testnum/)) {
            next; # skip netrcNnn of other tests
        }
        if(($log =~ /^trace\d+/) && ($log !~ /^trace$testnum/)) {
            next; # skip traceNnn of other tests
        }
        if(($log =~ /^valgrind\d+/) && ($log !~ /^valgrind$testnum(?:\..*)?$/)) {
            next; # skip valgrindNnn of other tests
        }
        if(($log =~ /^test$testnum$/)) {
            next; # skip test$testnum since it can be very big
        }
        logmsg "=== Start of file $log\n";
        displaylogcontent("$LOGDIR/$log");
        logmsg "=== End of file $log\n";
    }
}

#######################################################################
# Setup CI Test Run
citest_starttestrun();

#######################################################################
# The main test-loop
#

my $failed;
my $failedign;
my $ok=0;
my $ign=0;
my $total=0;
my $lasttest=0;
my @at = split(" ", $TESTCASES);
my $count=0;

$start = time();

foreach my $testnum (@at) {

    $lasttest = $testnum if($testnum > $lasttest);
    $count++;

    # execute one test case
    my $error = singletest($testnum, $count, scalar(@at));

    # Submit the test case result with the CI environment
    citest_finishtest($testnum, $error);

    if($error < 0) {
        # not a test we can run
        next;
    }

    $total++; # number of tests we've run

    if($error>0) {
        if($error==2) {
            # ignored test failures
            $failedign .= "$testnum ";
        }
        else {
            $failed.= "$testnum ";
        }
        if($postmortem) {
            # display all files in $LOGDIR/ in a nice way
            displaylogs($testnum);
        }
        if($error==2) {
            $ign++; # ignored test result counter
        }
        elsif(!$anyway) {
            # a test failed, abort
            logmsg "\n - abort tests\n";
            last;
        }
    }
    elsif(!$error) {
        $ok++; # successful test counter
    }

    # loop for next test
}

my $sofar = time() - $start;

#######################################################################
# Finish CI Test Run
citest_finishtestrun();

# Tests done, stop the servers
my $unexpected = stopservers($verbose);

my $numskipped = %skipped ? sum values %skipped : 0;
my $all = $total + $numskipped;

runtimestats($lasttest);

if($all) {
    logmsg "TESTDONE: $all tests were considered during ".
        sprintf("%.0f", $sofar) ." seconds.\n";
}

if(%skipped && !$short) {
    my $s=0;
    # Temporary hash to print the restraints sorted by the number
    # of their occurrences
    my %restraints;
    logmsg "TESTINFO: $numskipped tests were skipped due to these restraints:\n";

    for(keys %skipped) {
        my $r = $_;
        my $skip_count = $skipped{$r};
        my $log_line = sprintf("TESTINFO: \"%s\" %d time%s (", $r, $skip_count,
                           ($skip_count == 1) ? "" : "s");

        # now gather all test case numbers that had this reason for being
        # skipped
        my $c=0;
        my $max = 9;
        for(0 .. scalar @teststat) {
            my $t = $_;
            if($teststat[$t] && ($teststat[$t] eq $r)) {
                if($c < $max) {
                    $log_line .= ", " if($c);
                    $log_line .= $t;
                }
                $c++;
            }
        }
        if($c > $max) {
            $log_line .= " and ".($c-$max)." more";
        }
        $log_line .= ")\n";
        $restraints{$log_line} = $skip_count;
    }
    foreach my $log_line (sort {$restraints{$b} <=> $restraints{$a}} keys %restraints) {
        logmsg $log_line;
    }
}

if($total) {
    if($failedign) {
        logmsg "IGNORED: failed tests: $failedign\n";
    }
    logmsg sprintf("TESTDONE: $ok tests out of $total reported OK: %d%%\n",
                   $ok/$total*100);

    if($failed && ($ok != $total)) {
        logmsg "\nTESTFAIL: These test cases failed: $failed\n\n";
    }
}
else {
    logmsg "\nTESTFAIL: No tests were performed\n\n";
    if(scalar(keys %enabled_keywords)) {
        logmsg "TESTFAIL: Nothing matched these keywords: ";
        for(keys %enabled_keywords) {
            logmsg "$_ ";
        }
        logmsg "\n";
    }
}

if(($total && (($ok+$ign) != $total)) || !$total || $unexpected) {
    exit 1;
}
