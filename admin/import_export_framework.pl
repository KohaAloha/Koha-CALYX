#!/usr/bin/perl

# Copyright 2010-2011 MASmedios.com y Ministerio de Cultura
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.


use Modern::Perl;
use CGI qw ( -utf8 );
use CGI::Cookie;
use C4::Context;
use C4::Auth qw/check_cookie_auth/;
use C4::ImportExportFramework;

my %cookies = CGI::Cookie->fetch();
my $authenticated = 0;
my ($auth_status, $sessionID);
if (exists $cookies{'CGISESSID'}) {
    ($auth_status, $sessionID) = check_cookie_auth(
        $cookies{'CGISESSID'}->value,
        { parameters => 'manage_marc_frameworks' },
    );
}
if ($auth_status eq 'ok') {
    $authenticated = 1;
}

my $input = new CGI;

unless ($authenticated) {
    print $input->header(-type => 'text/plain', -status => '403 Forbidden');
    exit 0;
}

my $framework_name = $input->param('frameworkcode') || 'default';
my $frameworkcode = ($framework_name eq 'default') ? q{} : $framework_name;
my $action = $input->param('action') || 'export';

## Exporting
if ($action eq 'export' && $input->request_method() eq 'GET') {
    my $strXml = '';
    my $format = $input->param('type_export_' . $framework_name);
    ExportFramework($frameworkcode, \$strXml, $format);

    if ($format eq 'csv') {
        # CSV file

        # Correctly set the encoding to output plain text in UTF-8
        binmode(STDOUT,':encoding(UTF-8)');
        print $input->header(-type => 'application/vnd.ms-excel', -attachment => 'export_' . $framework_name . '.csv');
        print $strXml;
    } elsif ($format eq 'excel') {
        # Excel-xml file
        print $input->header(-type => 'application/excel', -attachment => 'export_' . $framework_name . '.xml');
        print $strXml;
    } else {
        # ODS file
        my $strODS = '';
        createODS($strXml, 'en', \$strODS);
        print $input->header(-type => 'application/vnd.oasis.opendocument.spreadsheet', -attachment => 'export_' . $framework_name . '.ods');
        print $strODS;
    }
## Importing
} elsif ($input->request_method() eq 'POST') {
    my $ok = -1;
    my $fieldname = 'file_import_' . $framework_name;
    my $filename = $input->param($fieldname);
    # upload the input file
    if ($filename && $filename =~ /\.(csv|ods|xml)$/i) {
        my $extension = $1;
        my $uploadFd = $input->upload($fieldname);
        if ($uploadFd && !$input->cgi_error) {
            my $tmpfilename = $input->tmpFileName(scalar $input->param($fieldname));
            $filename = $tmpfilename . '.' . $extension; # rename the tmp file with the extension
            $ok = ImportFramework($filename, $frameworkcode, 1) if (rename($tmpfilename, $filename));
        }
    }
    if ($ok >= 0) { # If everything went ok go to the framework marc structure
        print $input->redirect( -location => '/cgi-bin/koha/admin/marctagstructure.pl?frameworkcode=' . $frameworkcode);
    } else {
        # If something failed go to the list of frameworks and show message
        print $input->redirect( -location => '/cgi-bin/koha/admin/biblio_framework.pl?error_import_export=' . $frameworkcode);
    }
}

=c
sub takes and returns a $scalar holding the file contents

openoffice will import a 'happy' csv file, and save it as a csv file that Koha will no longer import :/
this sub() reformats an OO 'bad' csv file, and reformats it so Koha will import it successfully

so, bad csv like this...
------------------------
"tagfield","liblibrarian","libopac","repeatable","mandatory","authorised_value","frameworkcode",,,,,,,,,,,
"000","ZZZ","LEADER",0,1,,,,,,,,,,,,,
"001","CONTROL NUMBER","CONTROL NUMBER",0,0,,,,,,,,,,,,,
,,,,,,,,,,,,,,,,,
"#-#","#-#","#-#","#-#","#-#","#-#","#-#",,,,,,,,,,,
,,,,,,,,,,,,,,,,,
"tagfield","tagsubfield","liblibrarian","libopac","repeatable","mandatory","kohafield","tab","authorised_value","authtypecode","value_builder","isurl","hidden","frameworkcode","seealso","link","defaultvalue","maxlength"
"000","@","fixed length control field","fixed length control field",0,1,,0,,,"marc21_leader.pl",0,0,,,,,24
"001","@","control field","control field",0,0,,0,,,,0,0,,,,,9999
,,,,,,,,,,,,,,,,,
"#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#"
------------------------


is corrected to this...
------------------------
"tagfield","liblibrarian","libopac","repeatable","mandatory","authorised_value","frameworkcode"
"000","ZZZ","LEADER","0","1","","CF"
"001","CONTROL NUMBER","CONTROL NUMBER","0","0","","CF"

"#-#","#-#","#-#","#-#","#-#","#-#","#-#"

"tagfield","tagsubfield","liblibrarian","libopac","repeatable","mandatory","kohafield","tab","authorised_value","authtypecode","value_builder","isurl","hidden","frameworkcode","seealso","link","defaultvalue","maxlength"
"000","@","fixed length control field","fixed length control field","0","1","","0","","","marc21_leader.pl","0","0","CF","","","","24"
"001","@","control field","control field","0","0","","0","","","","0","0","CF","","","","9999"

"#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#","#-#"

------------------------

note the lazy quoting and trailing ',,,,,' commas, in the 1st example
these both cause Koha's importation process to fail :/

=cut


sub _fix_openoffice_csv {

    my $data = shift;

    # replace glitchy WIN/DOS line endings
    $data =~ s/\r\n/\n/g;

    my @lines1;
    my @lines2;

    my $tagstring;
    $tagstring = 0;
    #process 1st block to csv
    foreach my $l1 ( split /\n/, $data ) {
        $tagstring++ if $l1 =~ m/tagfield/;
        last if $tagstring == 2;

        #    $line = '\n' if $line =~ m/,,,,,,,,,,,,,,,,,//;

        $l1 =~ s/,,,,,,,,,,,$//;    # strip
        $l1 =~ s/^,,,,,,$//;        # strip
        push @lines1, $l1;

    }

    # each csv block is a diff. lenght and format, so we need 2 block to handle this...
    # process 2nd block to csv
    $tagstring = 0;
    foreach my $l2 ( split /\n/, $data ) {

        $tagstring++ if $l2 =~ m/tagfield/;
        next unless $tagstring == 2;

        $l2 =~ s/,,,,,,,,,,,,,,,,,$//;
        push @lines2, $l2;

    }

    my $data2;
    foreach my $line ( @lines1, @lines2 ) {
        $line =~ s/,,,$//;

        #    warn $line;

        my $csv  = Text::CSV->new( { always_quote => 1 } );
        my $csv2 = Text::CSV->new( { always_quote => 1 } );

        #$line2   = $csv->string();             # get the combined string

        $csv->parse($line);    # parse a CSV string into fields
        my @columns = $csv->fields();    # get the parsed fields

        #  zzz @columns;

        $csv2->combine(@columns);
        my $line2;
        $line2 = $csv2->string();

        $line2 =~ s/^""$//;              # clean blank lines

        $data2 .= "$line2\n";

    }

    $data2 .= "\n";

    #zzz $data2;
    return $data2;
}

