package C4::Carousel;

# Copyright 2013 CALYX
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA

use strict;
use warnings;

# use utf8;
# Force MARC::File::XML to use LibXML SAX Parser
#$XML::SAX::ParserPackage = "XML::LibXML::SAX";

use C4::Koha;
use C4::Biblio;

#use C4::Dates qw/format_date/;
use LWP::Simple;
use LWP::UserAgent;
use JSON;

use List::Util qw(shuffle);
#use DDP alias => 'zzz', colored => 0, caller_info => 1;

use vars qw($VERSION @ISA @EXPORT);

BEGIN {
    $VERSION = 1.00;

    require Exporter;
    @ISA = qw( Exporter );

    push @EXPORT, qw(
      &GetNewBiblios
    );
}

=head1 NAME

C4::Carousel

=head1 DESCRIPTION

=cut

my $dbh = C4::Context->dbh;

use Time::HiRes qw/gettimeofday tv_interval/;

sub GetNewBiblios {

    my $branch = shift();

    my $res1 = GetNewBibliosAmazon($branch);
    my $res2 = GetNewBibliosLocal($branch);

    my @res3 = shuffle( @$res1, @$res2 );
    @res3 = @res3[ 0 .. 9 ] if scalar @res3 > 10;

    return \@res3;
}

sub GetNewBibliosAmazon {

    my $branch = shift();

    my ($bibs)    = 0;
    my ($fetches) = 0;
    my @results;
    my @recents;

    my $ua = new LWP::UserAgent( 'max_redirect' => 0 );

    my $q = qq|
       SELECT biblioitems.isbn, items.biblionumber, items.dateaccessioned, items.homebranch  from items 
join biblioitems ON  (biblioitems.biblionumber = items.biblionumber ) 
where biblioitems.isbn is not null   |;

    my @bind;
    if ($branch) {
        $q .= qq| and homebranch = ?|;
        push @bind, $branch;
    }

    $q .= qq|    ORDER BY dateaccessioned  DESC LIMIT 1000   |;

    #       C4::Context->dbh->trace(1);
    my @recents_tmp =
      @{ $dbh->selectall_arrayref( $q, { Slice => {} }, @bind ) };

    #    C4::Context->dbh->trace(0);

    my $tt0   = [gettimeofday];
    my $total = 0;

    #    warn '-----------------------------------------------';

    # a quick sort, to remove bad rows - and give us 30 good rows
    #    warn scalar @recents_tmp;

    my $cache_add  = 0;
    my $cache_miss = 0;


    foreach my $rec (@recents_tmp) {
#        warn '-----------------------------------------------';
        my @isbns = split / |\|/, $rec->{'isbn'};

#        zzz $rec->{'isbn'};
        foreach my $ii (@isbns) {
            my $isbn = Business::ISBN->new($ii);
            if (  $isbn->{valid} &&  $isbn->{valid} ==  1 ) {

                my $isbn10 = $isbn->as_isbn10;    

                $rec->{'isbn'} = $isbn10->{isbn};
                last;
            }
        }

        next unless $rec->{'isbn'};
        $rec->{'isbn'} = substr $rec->{'isbn'} , 0, 13; 

#        warn '-----------------------------------------------';
#exit;

        # check for dups...
        my $dupe = 0;
        foreach my $r (@recents) {
            if ( $rec->{isbn} eq $r->{isbn} ) {
                $dupe = 1;
                last;
            }

        }
        next if $dupe == 1;
        push @recents, $rec;

        last if scalar @recents > 300;
    }

    my $i = 0;

    @recents = shuffle @recents;
    foreach my $rec (@recents) {

        last if scalar @results == 10;

        my $hits = scalar @results;

        my $sth = $dbh->prepare("SELECT * from isbn_image_url where isbn = ? ");
        $sth->execute( $rec->{'isbn'} );

        my $row       = $sth->fetchrow_hashref;
        my $image_url = $row->{url};

        if ( defined $image_url and $image_url eq 'xxx' ) {

            #          warn "MISS FROM local CACHE!!!!";
            next;
        }
        else {

            #     warn '  got a match';
        }

        my ( $t0, $t1, $str, $req, $res, $elapsed, $headers );

        $t1 = [gettimeofday];
        $elapsed = tv_interval( $t0, $t1 );

        #      warn $elapsed;
        $total += $elapsed;

        unless ($image_url) {

            # no row in db...
            $t0 = [gettimeofday];

            $image_url =

              'https://images-na.ssl-images-amazon.com/images/P/'
              . $rec->{isbn}
              . '.01._THUMBZZZ.jpg';

            $req = HTTP::Request->new( 'GET', $image_url );
            $res = $ua->request($req);
            my $res_size = $res->headers->{'content-length'};

            #            my $response = $res;

            my $thumb;
            if ( $res_size > 43 ) {

                $thumb = $image_url;

            }

            $image_url = $thumb if defined $thumb;

            $fetches++;

            if ($thumb) {
                warn 'ADD HIT TO CACHE: ' . $rec->{'isbn'} . " $image_url ";
                $cache_add++;
            }
            else {
                warn 'ADD MISS TO CACHE: ' . $rec->{'isbn'};
                $image_url = 'xxx';
                $cache_miss++;

            }

            my $sth = $dbh->prepare( "
                INSERT INTO isbn_image_url (isbn, url) VALUES ( ?, ?  )
            " );

            my $rc = $sth->execute( $rec->{'isbn'}, $image_url );

            next if $image_url eq 'xxx';

        }

        my $bib = GetBiblioData( $rec->{biblionumber} );

        $rec->{image_url} = $image_url ? $image_url : $str;
        $rec->{title}     = $bib->{title};
        $rec->{author}    = $bib->{author};

        push @results, $rec;

        $bibs++;
        $i++;
    }

    my @results2 = @results;

    #---------------------------

    my $tt1 = [gettimeofday];

    warn 'caro speed ' . tv_interval( $tt0, $tt1 ) .", total_bibs:$i, queries:$fetches";
    warn "cache_adds:$cache_add, cache_miss:$cache_miss, success:"
      . scalar @results2;

    return \@results2;
}

sub GetNewBibliosLocal {

    #  warn '------------------------------------------';

    my $branch = shift();

    my ($bibs)    = 0;
    my ($fetches) = 0;
    my @results;
    my @recents;

    my $q = qq|


   SELECT distinct(items.biblionumber),  imagenumber, items.dateaccessioned, items.homebranch  from items 
join biblioimages  ON  (biblioimages.biblionumber = items.biblionumber ) 

  |;

    my @bind;
    if ($branch) {

        #        $q .= qq| and homebranch = ?|;
        #        push @bind, $branch;
    }

    $q .= qq|    ORDER BY dateaccessioned  DESC LIMIT 100   |;

    #    C4::Context->dbh->trace(1);
    @recents =
      @{ $dbh->selectall_arrayref( $q, { Slice => {} }, @bind ) };

    #    C4::Context->dbh->trace(0);

    my $tt0   = [gettimeofday];
    my $total = 0;

    #    warn '-----------------------------------------------';

    # a quick sort, to remove bad rows - and give us 30 good rows
    #    warn scalar @recents_tmp;

    my $i = 0;

    # -------------------------

    #my @results = shuffle @recents;
    @recents = shuffle @recents;

    foreach my $rec (@recents) {

        my $bib = GetBiblioData( $rec->{biblionumber} );
#        zzz $bib;

        $rec->{image_url} = '/cgi-bin/koha/opac-image.pl?biblionumber='
          . $rec->{biblionumber};

        $rec->{title}  = $bib->{title};
        $rec->{author} = $bib->{author};

        push @results, $rec;

        $bibs++;

        last if $i == 10;
    }

    #---------------------------
    # now we have 30 of the most recent bibs, lets select 10 randomly...

    my @results2 = @results;

    #    warn scalar @results2;
    #    zzz  @results2;

    #---------------------------

    my $tt1 = [gettimeofday];

#    warn 'caro speed ' . tv_interval( $tt0, $tt1 ), ", total_bibs:$i, queries:$fetches";

    return \@results2;
}

1;

__END__

=head1 AUTHOR

Koha Developement team <info@koha-community.org>

=cut
