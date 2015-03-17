#!/usr/bin/env perl

use strict;
use warnings;
use feature qw(say);
use autodie;
use IPC::System::Simple qw(system);
use Carp::Always;
use Carp qw(croak);
use Getopt::Long;
use Data::UUID;
use FindBin qw($Bin);
use lib "$Bin/../gt-download-upload-wrapper/lib/";

use GNOS::Upload;

#########################################################################################################
# DESCRIPTION                                                                                           #
#########################################################################################################
# This tool takes a metadata file and a URL and fastq file path. It then parses the metadata            #
# file, generates the new submission metadata files, and then performs the uploads to the               #
# specified GNOS repository                                                                             #
# See https://github.com/SeqWare/public-workflows/blob/develop/fastq-uploader/README.md                 #
# Also see https://wiki.oicr.on.ca/display/PANCANCER/PCAWG+RNA-Seq+fastq+Sequence+Submission+SOP+-+v0.9 #
#########################################################################################################

#############
# VARIABLES #
#############

# minutes to wait for a retry
my $cooldown = 1;
# 30 retries at 60 seconds each is 30 hours
my $retries = 30;
# retries for md5sum, 4 hours
my $md5_sleep = 240;

my $fastq;
my $md5_file = q{};
my $output_dir    = "test_output_dir";
my $key           = "gnostest.pem";
my $upload_url    = q{};
my $study_ref_name  = "icgc_pancancer";
my $analysis_center = "OICR";
my $metadata;
my $force_copy         = q{};
my $test          = q{};
my $skip_validate = q{};
my $skip_upload   = q{};


if ( scalar(@ARGV) < 12 || scalar(@ARGV) > 22 ) {
    die "USAGE: 'perl gnos_upload_fastq.pl
       --fastq <file for fastq file tarball>
       --metadata <file containing key value pairs>
       --fastq-md5sum-file <file_with_fastq_md5sum>
       --outdir <output_dir>
       --key <gnos.pem>
       --upload-url <gnos_server_url>
       [--study-refname-override <study_refname_override>]
       [--analysis-center-override <analysis_center_override>]
       [--make-runxml]
       [--make-expxml]
       [--force-copy]
       [--skip-validate]
       [--skip-upload]
       [--test]
       gnos_upload_fastq.pl  --fastq <your_fastq.tar.gz>  --fastq-md5sum-file <your_fastq.tar.gz.md5 --outdir <your_outdir> --upload-url <https://gtrepo-ebi.annailabs.com> --key <full/path/to/your/gnos_key.pem> --metadata <your_metadata_file.txt>\n";
}

GetOptions(
    "fastq=s"                    => \$fastq,
    "metadata=s"                 => \$metadata,
    "fastq-md5sum-file=s"        => \$md5_file,
    "outdir=s"                   => \$output_dir,
    "key=s"                      => \$key,
    "upload-url=s"               => \$upload_url,
    "study-refname-override=s"   => \$study_ref_name,
    "analysis-center-override=s" => \$analysis_center,
    "force-copy"                 => \$force_copy,
    "skip-validate"              => \$skip_validate,
    "skip-upload"                => \$skip_upload,
    "test"                       => \$test,
);

##############
# MAIN STEPS #
##############

# setup output dir
say "SETTING UP OUTPUT DIR";

my $uuid = q{};
my $ug = Data::UUID->new;

if( -d "$output_dir" ) {
    opendir( my $dh, $output_dir );
    my @dirs = grep {-d "$output_dir/$_" && ! /^\.{1,2}$/} readdir($dh);
    if (scalar @dirs == 1) {
        $uuid = $dirs[0];
    }
    else {
        $uuid = lc($ug->create_str());
    }
}
else {
    $uuid = lc($ug->create_str());
}

$output_dir = "fastq/$output_dir";
run("mkdir -p $output_dir/$uuid");
$output_dir = "$output_dir/$uuid";

my $final_touch_file = $output_dir."/upload_complete.txt";

say 'COPYING FILES TO OUTPUT DIR';

my $link_method = ($force_copy)? 'rsync -rauv': 'ln -s';
my $pwd = `pwd`;
chomp $pwd;

my @files = ( $fastq, $md5_file, );

foreach my $file (@files) {
    my $command = "$link_method $pwd/$file $output_dir";
    run($command) unless ( -e "$pwd/$output_dir/$file" );
}

say 'READING METADATA FILE';
my $FH;
open $FH, '<', $metadata or die "Could not open $metadata for reading";
my $metad = {};

while ( <$FH> ) {
    chomp;
    my ( $key, $value, ) = m/^([^:]+):(.+)$/;
    $metad->{$key} = $value;
}

$metad->{study} = $study_ref_name;

unless ( exists $metad->{includes_spike_ins} ) {
    $metad->{includes_spike_ins} = 'no';
}

unless ( exists $metad->{spike_ins_fasta} ) {
    $metad->{spike_ins_fasta} = 'N/A';
}

unless ( exists $metad->{spike_ins_concentration} ) {
    $metad->{spike_ins_concentration} = 'N/A';
}

unless ( exists $metad->{icgc_donor_id} ) {
    $metad->{icgc_donor_id} = 'NONE';
}

unless ( exists $metad->{icgc_specimen_id} ) {
    $metad->{icgc_specimen_id} = 'NONE';
}

unless ( exists $metad->{icgc_sample_id} ) {
    $metad->{icgc_sample_id} = 'NONE';
}

say 'GENERATING SUBMISSION';
my $sub_path = generate_submission( $metad, );

say 'VALIDATING SUBMISSION';
die "The submission did not pass validation! Files are located at: $sub_path\n"
                                                       if ( validate_submission($sub_path) );

say 'UPLOADING SUBMISSION';
die "The upload of files did not work!  Files are located at: $sub_path\n"
                                                       if ( upload_submission($sub_path) );

###############
# SUBROUTINES #
###############

sub validate_submission {
    my ( $sub_path, ) = @_;

    my $cmd = "cgsubmit --validate-only -s $upload_url -o validation.log -u $sub_path -vv";
    say "VALIDATING: $cmd";
    unless ( $skip_validate ) {
        die "ABORT: No cgsubmit installed, aborting!" if ( system("which cgsubmit") );
        return run($cmd);
    }
} # close sub

sub upload_submission {
    my ($sub_path) = @_;

    my $cmd = "cgsubmit -s $upload_url -o metadata_upload.log -u $sub_path -vv -c $key";
    say "UPLOADING METADATA: $cmd";
    if ( not $test && not $skip_upload ) {
        croak "ABORT: No cgsubmit installed, aborting!" if( system("which cgsubmit"));
        return 1 if ( run($cmd) );
    }

    my $log_file = 'upload.log';
    my $gt_upload_command = "cd $sub_path; gtupload -v -c $key -l ./$log_file -u ./manifest.xml; cd -";
    say "UPLOADING DATA: $gt_upload_command";

    unless ( $test ) {
        die "ABORT: No gtupload installed, aborting!" if ( system("which gtupload") );
        return 1 if ( GNOS::Upload->run_upload($gt_upload_command, "$sub_path/$log_file", $retries, $cooldown, $md5_sleep) );
    }

    # just touch this file to ensure monitoring tools know upload is complete
    run("date +\%s > $final_touch_file", "metadata_upload.log");

    return 0;
} # close sub

sub generate_submission {
    my ( $m, ) = @_;
    my $datetime = $m->{DT};
    my $refcenter = "OICR";
    my $study_name = $m->{study};
    my $dcc_project_code = $m->{dcc_project_code};
    my $dcc_specimen_type = $m->{dcc_specimen_type};
    my $submitter_sample_id = $m->{submitter_sample_id};
    my $submitter_specimen_id = $m->{submitter_specimen_id};
    my $submitter_donor_id = $m->{submitter_donor_id};
    my $sample_uuid = $m->{SM};
    my $aliquot_id = $m->{aliquot_id};
    my $library = $m->{LB};
    my $read_group_label = $m->{ID};
    my $platform = $m->{PL};
    my $platform_model = $m->{PM};
    my $platform_unit = $m->{PU};
    my $participant_id = $m->{submitter_donor_id};
    my $center_name = $m->{CN};
    my $run = $platform_unit;
    my $exp = $run . ':' . $library;
    my $md5_sum = $m->{md5sum};
    my $includes_spike_ins = $m->{includes_spike_ins};
    my $spike_ins_fasta = $m->{spike_ins_fasta};
    my $spike_ins_concentration = $m->{spike_ins_concentration};
    my $icgc_donor_id = $m->{icgc_donor_id};
    my $icgc_specimen_id = $m->{icgc_specimen_id};
    my $icgc_sample_id = $m->{icgc_sample_id};
    my $accession = $m->{accession};
    my $library_type = $m->{library_type};
    my $library_selection = $m->{library_selection};

    my $analysis_xml = <<ANALYSISXML;
<ANALYSIS_SET xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.ncbi.nlm.nih.gov/viewvc/v1/trunk/sra/doc/SRA_1-5/SRA.analysis.xsd?view=co">
  <ANALYSIS center_name="$center_name" analysis_date="$datetime" >
    <TITLE>ICGC PanCancer FASTQ file tarball GNOS Upload</TITLE>
    <STUDY_REF accession="$accession" refcenter="$refcenter" refname="$study_name"/>
    <DESCRIPTION>RNA-Seq fastq tarball upload for: $aliquot_id</DESCRIPTION>
    <ANALYSIS_TYPE>
      <REFERENCE_ALIGNMENT>
        <ASSEMBLY>
          <STANDARD short_name="unaligned"/>
        </ASSEMBLY>
        <RUN_LABELS>
          <RUN refcenter="$center_name" refname="$run" read_group_label="$read_group_label" data_block_name="$library"/>
        </RUN_LABELS>
        <SEQ_LABELS>
          <SEQUENCE accession="NA" data_block_name="NA" seq_label="NA"/>
        </SEQ_LABELS>
        <PROCESSING>
          <DIRECTIVES>
            <alignment_includes_unaligned_reads>true</alignment_includes_unaligned_reads>
            <alignment_marks_duplicate_reads>false</alignment_marks_duplicate_reads>
            <alignment_includes_failed_reads>false</alignment_includes_failed_reads>
          </DIRECTIVES>
          <PIPELINE>
            <PIPE_SECTION>
              <STEP_INDEX>NA</STEP_INDEX>
              <PREV_STEP_INDEX>NA</PREV_STEP_INDEX>
              <PROGRAM>gnos_upload_fastq.pl</PROGRAM>
              <VERSION>0.001</VERSION>
              <NOTES></NOTES>
            </PIPE_SECTION>
          </PIPELINE>
        </PROCESSING>
      </REFERENCE_ALIGNMENT>
    </ANALYSIS_TYPE>
    <TARGETS>
      <TARGET refcenter="OICR" refname="$aliquot_id" sra_object_type="SAMPLE"/>
    </TARGETS>
    <DATA_BLOCK name="$aliquot_id">
      <FILES>
        <FILE checksum="$md5_sum" checksum_method="MD5" filetype="fasta" filename="$fastq"/>
      </FILES>
    </DATA_BLOCK>
    <ANALYSIS_ATTRIBUTES>
      <ANALYSIS_ATTRIBUTE>
        <TAG>dcc_project_code</TAG>
        <VALUE>$dcc_project_code</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>submitter_donor_id</TAG>
        <VALUE>$submitter_donor_id</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>submitter_specimen_id</TAG>
        <VALUE>$submitter_specimen_id</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>submitter_sample_id</TAG>
        <VALUE>$submitter_sample_id</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>dcc_specimen_type</TAG>
        <VALUE>$dcc_specimen_type</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>use_cntl</TAG>
        <VALUE>N/A</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>includes_spike_ins</TAG>
        <VALUE>$includes_spike_ins</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>spike_ins_fasta</TAG>
        <VALUE>$spike_ins_fasta</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>spike_ins_concentration</TAG>
        <VALUE>$spike_ins_concentration</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>icgc_donor_id</TAG>
        <VALUE>$icgc_donor_id</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>icgc_specimen_id</TAG>
        <VALUE>$icgc_specimen_id</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>icgc_sample_id</TAG>
        <VALUE>$icgc_sample_id</VALUE>
      </ANALYSIS_ATTRIBUTE>
      <ANALYSIS_ATTRIBUTE>
        <TAG>library_type</TAG>
        <VALUE>$library_type</VALUE>
      </ANALYSIS_ATTRIBUTE>
    </ANALYSIS_ATTRIBUTES>
  </ANALYSIS>
</ANALYSIS_SET>
ANALYSISXML

    open my $out, '>', "$output_dir/analysis.xml";
    print $out $analysis_xml;
    close $out;

    my $exp_xml = <<END;
<EXPERIMENT_SET xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.ncbi.nlm.nih.gov/viewvc/v1/trunk/sra/doc/SRA_1-5/SRA.experiment.xsd?view=co">
END

    $exp_xml .= <<END;
<EXPERIMENT center_name="$center_name" alias="$exp">
  <STUDY_REF accession= "$accession" refcenter="OICR" refname="$study_name"/>
    <DESIGN>
      <DESIGN_DESCRIPTION>ICGC RNA-Seq Paired-End Experiment</DESIGN_DESCRIPTION>
      <SAMPLE_DESCRIPTOR refcenter="OICR" refname="$aliquot_id"/>
      <LIBRARY_DESCRIPTOR>
        <LIBRARY_NAME>"$library"</LIBRARY_NAME>
        <LIBRARY_STRATEGY>RNA-Seq</LIBRARY_STRATEGY>
        <LIBRARY_SOURCE>TRANSCRIPTOMIC</LIBRARY_SOURCE>
        <LIBRARY_SELECTION>$library_selection</LIBRARY_SELECTION>
        <LIBRARY_LAYOUT>
          <PAIRED/>
        </LIBRARY_LAYOUT>
      </LIBRARY_DESCRIPTOR>
      <SPOT_DESCRIPTOR>
        <SPOT_DECODE_SPEC>
          <READ_SPEC>
            <READ_INDEX>0</READ_INDEX>
            <READ_CLASS>Application Read</READ_CLASS>
            <READ_TYPE>Forward</READ_TYPE>
            <BASE_COORD>1</BASE_COORD>
          </READ_SPEC>
          <READ_SPEC>
            <READ_INDEX>1</READ_INDEX>
            <READ_CLASS>Application Read</READ_CLASS>
            <READ_TYPE>Reverse</READ_TYPE>
            <BASE_COORD>47</BASE_COORD>
          </READ_SPEC>
        </SPOT_DECODE_SPEC>
      </SPOT_DESCRIPTOR>
    </DESIGN>
    <PLATFORM>
      <ILLUMINA>
        <INSTRUMENT_MODEL>$platform_model</INSTRUMENT_MODEL>
      </ILLUMINA>
    </PLATFORM>
    <PROCESSING>
      <PIPELINE>
        <PIPE_SECTION section_name="BASE_CALLS">
          <STEP_INDEX>N/A</STEP_INDEX>
          <PREV_STEP_INDEX>NIL</PREV_STEP_INDEX>
          <PROGRAM></PROGRAM>
          <VERSION></VERSION>
          <NOTES>
            SEQUENCE_SPACE=Base Space
          </NOTES>
        </PIPE_SECTION>
        <PIPE_SECTION section_name="QUALITY_SCORES">
          <STEP_INDEX>N/A</STEP_INDEX>
          <PREV_STEP_INDEX>NIL</PREV_STEP_INDEX>
          <PROGRAM></PROGRAM>
          <VERSION></VERSION>
          <NOTES></NOTES>
        </PIPE_SECTION>
      </PIPELINE>
      <DIRECTIVES></DIRECTIVES>
    </PROCESSING>
  </EXPERIMENT>
</EXPERIMENT_SET>
END

    open $out, '>', "$output_dir/experiment.xml";
    print $out $exp_xml;
    close $out;

    my $run_xml = <<END;
  <RUN_SET xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.ncbi.nlm.nih.gov/viewvc/v1/trunk/sra/doc/SRA_1-5/SRA.run.xsd?view=co">
END

    $run_xml .= <<END;
    <RUN center_name="$center_name" alias="$run">
        <EXPERIMENT_REF refcenter="$center_name" refname="$exp"/>
    </RUN>
END
    
    $run_xml .= <<END;
  </RUN_SET>
END
 
    open $out, '>', "$output_dir/run.xml";
    print $out $run_xml;
    close $out;

    return ($output_dir);
} # close sub

sub run {
    my ( $cmd, $do_die, ) = @_;

    say "CMD: $cmd";
    my $result = system($cmd);
    if ( $do_die && $result ) {
        croak "ERROR: CMD '$cmd' returned non-zero status";
    }
    return ($result);
} # close sub

0;

exit;

__END__

=head1 NAME
 
gnos_upload_fastq.pl - Generates metadata files and uploads metadata and fastq files into a GNOS repository
  
=head1 VERSION
 
This documentation refers to gnos_upload_fastq.pl version 1.0.2
 
=head1 USAGE

 gnos_upload_fastq.pl  --fastq <your_fastq.tar.gz>  --fastq-md5sum-file <your_fastq.tar.gz.md5 --outdir <your_outdir> --upload-url <https://gtrepo-ebi.annailabs.com> --key <full/path/to/your/gnos_key.pem> --metadata <your_metadata_file.txt>;
  
=head1 REQUIRED ARGUMENTS

--fastq filename for your fastq file tarball

--fastq-md5sum-file filename containing the md5 checksum for your fastq file tar ball

--metadata filename containing colon-separated key=value pairs

--outdir the name of your output directory

--key the full path to the file containing your GNOS upload token

--upload-url the full URL to the GNOS repository of your choice
 
=head1 OPTIONS

--study-refname-override to provide a string for an alternative study

--analysis-center-override to provide a string for an alternative analysis center

--force-copy A flag that dictates whether the files (or just symlinks to the data files) get copied into
the UUID-named subdirectory

--skip-validate A flag indicating that you wish to execute the script but skip the step where the
newly create XML metadata files are validated by the cgsubmit script

--skip-upload A flag indicating that you wish to execute the script but skip the step where the
data files are uploaded into the GNOS repository of your choice

--test A flag indicating that this is just a 'test' run
 
=head1 DESCRIPTION

This script ingests a colon-separated text file containing key=value pairs of metadata for RNA-Seq fastq files
from the International Cancer Genome Consortium, and generates SRA-compatible XML metadata files.  The script then
invokes the cgsubmit and gtupload scripts to transfer the metadata and the data files to the GNOS
repository of your choice
 
=head1 DIAGNOSTICS

Carp::Always is currently providing stacktraces
 
=head1 DEPENDENCIES
 
GNOS::Upload

IPC::System::Simple for graceful and informative handling of errors from system calls

Carp::Always to generate informative stacktraces, no matter what

Getopt::Long;

Data::UUID

 
=head1 INCOMPATIBILITIES
 
None are known at this point.
  
=head1 BUGS AND LIMITATIONS
 
There are no known bugs in this script. 
Please report problems to Marc Perry (marc.perry@alumni.utoronto.ca)
 
=head1 AUTHOR
 
<Author name(s)>  (<contact address>)
 
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
