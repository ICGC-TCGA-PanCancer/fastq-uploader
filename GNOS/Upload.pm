package GNOS::Upload;

use warnings;
use strict;

use feature qw(say);
use Carp::Always;
use Carp qw( croak );

use Config;
$Config{useithreads} or croak('Recompile Perl with threads to run this program.');
use threads 'exit' => 'threads_only';
use Storable 'dclone';

use constant {
   MILLISECONDS_IN_AN_HOUR => 3600000
};

#############################################################################################
# DESCRIPTION                                                                               #
#############################################################################################
#  This module wraps the gtupload script and retries the upload if the first one freezes up.#
#############################################################################################
# USAGE: run_upload($command, $log_file, $retries, $cooldown_min, $timeout_min);            #
#        Where $command is the full gtupload command                                        #
#############################################################################################

sub run_upload {
    my ($class, $command, $log_file, $retries, $cooldown_min, $timeout_min) = @_;
    
    $retries //=30;
    $timeout_min //= 60;
    $cooldown_min //= 1;

    my $timeout_mili = ($timeout_min / 60) * MILLISECONDS_IN_AN_HOUR;
    my $cooldown_sec = $cooldown_min * 60;

    say "TIMEOUT: min $timeout_min milli $timeout_mili";
    my $thr = threads->create(\&launch_and_monitor, $command, $timeout_mili);

    my $count = 0;
    my $completed = 0;
    
    # pausing 60 seconds here so that the forked thread for the
    # initial gtupload command actually has time to create the
    # upload_log file
    sleep 60;

    do { 
        # checking if the gtupload command from the last thread
	# has completed yet
        open my $fh, '<', $log_file or die "Could not open $log_file for reading: $!";
        my @lines = <$fh>;
        close $fh;

        if ( {grep {/(100.000% complete)/s} @lines} ) {
            $thr->join() if ($thr->is_running());
            $completed = 1;
        } # check the state/status of the last thread you launched
        elsif (not $thr->is_running()) {
            # we need to launch a new thread
            if (++$count < $retries ) {
                say 'KILLING THE THREAD!!';
                # kill and wait to exit
                $thr->kill('KILL')->join();
                $thr = threads->create(\&launch_and_monitor, $command, $timeout_mili);
            }
            else {
                say "Surpassed the number of retries: $retries";
                exit 1;
            }
        }
	else {
            say "Monitoring thread will sleep now for $cooldown_sec seconds";
            sleep $cooldown_sec;
	}
    } until ( $completed );

    say "Total number of attempts: $count";
    say 'DONE';
    $thr->join() if ($thr->is_running());

    return 0;
} # close sub

sub launch_and_monitor {
    my ($command, $timeout) = @_;

    my $my_object = threads->self;
    my $my_tid = $my_object->tid;

    local $SIG{KILL} = sub { say "GOT KILL FOR THREAD: $my_tid";
                             threads->exit;
                           };

    my $pid = open my $in, '-|', "$command 2>&1";

    my $time_last_uploading = time;
    my $last_reported_uploaded = 0;

    while(<$in>) {
        if ( $_ =~ m/(100.000% complete)/s ) {
            print "$_";
            return 1;
	}
        else {
            # print the output for debugging reasons
            print "$_";
            my ($uploaded, $percent, $rate) = $_ =~ m/^Status:\s+(\d+.\d+|\d+| )\s+[M|G]B\suploaded\s*\((\d+.\d+|\d+| )%\s*complete\)\s*current\s*rate:\s*(\d+.\d+|\d+| )\s*[M|k]B\/s/g;

            my $md5sum = ($_ =~ m/^Download resumed, validating checksums for existing data/g)? 1: 0;

            if ( (defined($percent) && defined($last_reported_uploaded) && $percent > $last_reported_uploaded) || $md5sum ) {
                $time_last_uploading = time;
                if ( defined($md5sum) ) { say "  IS MD5Sum State: $md5sum"; }
                if ( defined($time_last_uploading) && defined($percent)) { say "  LAST REPORTED TIME $time_last_uploading SIZE: $percent"; }
            }
            elsif ( ($time_last_uploading != 0) and (time - $time_last_uploading) > $timeout ) {
                say 'ERROR: Killing Thread - Timed Out ' . time;
                exit;
            }
            $last_reported_uploaded = $percent;
        } # close if/else test
    } # close while loop
    return 0;
} # close sub

1;
__END__

=head1 NAME
 
GNOS::Upload - A helper module/wrapper to automate interactions with the GeneTorrent gtupload Python script
  
=head1 VERSION
 
This documentation refers to GNOS::Upload version 0.0.1
  
=head1 SYNOPSIS
 
    use GNOS::Upload;
    GNOS::Upload->run_upload($gt_upload_command, "$sub_path/$log_file", $retries, $cooldown, $md5_sleep);
      
=head1 DESCRIPTION
 
This module takes parameters provided by your script and will attempt to upload a fastq file tarball
into a GNOS repository.  If the upload is halted the script will automatically attempt to reconnect
to the GNOS repository and resume the file upload.
  
=head1 SUBROUTINES/METHODS 

=head2 run_upload() 

This is the only subroutine that gets called from an external script, it is expecting 5 parameters
in this order: (1) a string containing the full syntax for your gtupload command, (2) the relative path to
the gtupload logging file, (3) the number of times you wish the script to attempt to restart the gtupload
(e.g., in the event of a network timeout between your gtupload client and the GNOS server), (4) the length
of time to wait between retries, and (5) the time for something else that I am not really sure about.
N.B. The logic for monitoring success and failure of this subroutine may seem counterintuitive.
In other words it returns '0' on successful completion and it returns '1' on failure.

=head2 launch_and_monitor()

This subroutine gets by run_upload().  It monitors the STDERR from the
gtupload process (by reading in the contents of the log file and using a regex pattern match), and 
will actually relaunch the upload if the last attempt timed out before completion
 
=head1 DIAGNOSTICS

The module uses the Core module Carp to generate a stack trace for any
fatal exceptions.
 
=head1 CONFIGURATION AND ENVIRONMENT

The module uses the Core module Config to establish if your Perl version was compiled with threads
enabled, and dies gracefully if this flag is not set 
 
=head1 DEPENDENCIES

The module requires two additional Perl core modules: threads and Storable. 
 
=head1 INCOMPATIBILITIES
 
None are currently known.
 
=head1 BUGS AND LIMITATIONS
 
There are no known bugs in this module. 
Please report problems to <Maintainer name(s)>  (<contact address>)
Patches are welcome.
 
=head1 LICENCE AND COPYRIGHT
 
Copyright (c) 2015 Ontario Institute for Cancer Research (<contact address>). All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program; if not, write to the Free Software Foundation, Inc.,
51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
