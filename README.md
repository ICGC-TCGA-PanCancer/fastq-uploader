# README

## Overview

This tool is designed to upload one fastq.tar.gz file.  It is designed to be called manually.  gnos_upload_fastq.pl uploads files to a gnos repository.

This tool needs to produce fastq uploads that conform to the PanCancer fastq file upload spec, see https://wiki.oicr.on.ca/display/PANCANCER/PCAWG+RNA-Seq+fastq+Sequence+Submission+SOP+-+v0.1

## Dependencies for gnos_upload_fastq.pl

You can use PerlBrew (or your native package manager) to install dependencies.  For example:

    cpanm Data::UUID Carp::Always IPC::System::Simple

Once these are installed you can execute the script with the command below.

You also need the gtdownload/gtuplod/cgsubmit tools installed.  These are available on the CGHub site and are only available for Linux (for the submission tools).

## Inputs

This tool is designed to work with the following file types:

* tar.gz: a standard tar/gz file format made with something similar to 'tar zcf bar.tar.gz <files>'.
* tar.gz.md5: md5sum file made with something like 'md5sum bar.tar.gz | awk '{print$1}' > bar.tar.gz.md5'.

## Running gnos_upload_fastq

The parameters:

    perl gnos_upload_fastq.pl
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

For example:

gnos_upload_fastq.pl  --fastq <your_fastq.tar.gz>  --fastq-md5sum-file <your_fastq.tar.gz.md5 --outdir <your_outdir> --upload-url <https://gtrepo-ebi.annailabs.com> --key <full/path/to/your/gnos_key.pem> --metadata <your_metadata_file.txt>\n";

## Notes About GNOS Analysis XML

Here is an example of a metadata file.  The key=value pairs are largely derived from the uniformly aligned bam files from the same ICGC Project and Donor:

* ID:121002_UNC11-SN627_0254_AC0WP5ACXX_3_GTCCGC
* CN:UNC-LCCC
* PL:ILLUMINA
* PM:Illumina Genome Analyzer II
* LB:RNA-Seq:UNC-LCCC:Illumina TruSeq for 1e176d9d-dba9-4d41-946e-05b7f35eba64
* SM:1e176d9d-dba9-4d41-946e-05b7f35eba64
* PU:UNC-LCCC:2066824_1
* DT:2012-10-16T11:16:21.365
* dcc_project_code:CESC-US
* submitter_donor_id:0809ba8b-4ab6-4f43-934c-c1ccbc014a7e
* submitter_specimen_id:5f613800-55df-497f-a544-5b12cb9446ce
* submitter_sample_id:b3b3a27c-ee9a-42af-a6d1-9af5970a98b9
* dcc_specimen_type:Primary Tumour - solid tissue
* aliquot_id:1e176d9d-dba9-4d41-946e-05b7f35eba64
* md5sum:ffec1a6e359ee0dd55d72d7967b1ce06

These values were extracted from this TCGA unaligned RNA-Seq fastq file from the PanCancer Analysis Project:
https://cghub.ucsc.edu/cghub/metadata/analysisFull/29507bea-bf84-4b4e-902b-e7e42d70ca31
