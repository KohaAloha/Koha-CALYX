#!/usr/bin/perl

# Copyright 2009 PTFS, Inc.
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

use constant DEFAULT_ZEBRAQ_PURGEDAYS             => 30;
use constant DEFAULT_MAIL_PURGEDAYS               => 30;
use constant DEFAULT_IMPORT_PURGEDAYS             => 60;
use constant DEFAULT_LOGS_PURGEDAYS               => 180;
use constant DEFAULT_SEARCHHISTORY_PURGEDAYS      => 30;
use constant DEFAULT_SHARE_INVITATION_EXPIRY_DAYS => 14;
use constant DEFAULT_DEBARMENTS_PURGEDAYS         => 30;

BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/../kohalib.pl" };
}

use C4::Biblio;
use C4::Context;
use C4::Search;
use C4::Search::History;
use Getopt::Long;
use C4::Log;
use C4::Accounts;
use Koha::UploadedFiles;

sub usage {
    print STDERR <<USAGE;
Usage: $0 [-h|--help] [--sessions] [--sessdays DAYS] [-v|--verbose] [--zebraqueue DAYS] [-m|--mail] [--merged] [--import DAYS] [--logs DAYS] [--searchhistory DAYS] [--restrictions DAYS] [--all-restrictions] [--fees DAYS] [--temp-uploads] [--temp-uploads-days DAYS] [--uploads-missing 0|1 ]

   -h --help          prints this help message, and exits, ignoring all
                      other options
   --sessions         purge the sessions table.  If you use this while users 
                      are logged into Koha, they will have to reconnect.
   --sessdays DAYS    purge only sessions older than DAYS days.
   -v --verbose       will cause the script to give you a bit more information
                      about the run.
   --zebraqueue DAYS  purge completed zebraqueue entries older than DAYS days.
                      Defaults to 30 days if no days specified.
   -m --mail DAYS     purge items from the mail queue that are older than DAYS days.
                      Defaults to 30 days if no days specified.
   --merged           purged completed entries from need_merge_authorities.
   --import DAYS      purge records from import tables older than DAYS days.
                      Defaults to 60 days if no days specified.
   --z3950            purge records from import tables that are the result
                      of Z39.50 searches
   --fees DAYS        purge entries accountlines older than DAYS days, where
                      amountoutstanding is 0 or NULL.
                      In the case of --fees, DAYS must be greater than
                      or equal to 1.
   --logs DAYS        purge entries from action_logs older than DAYS days.
                      Defaults to 180 days if no days specified.
   --searchhistory DAYS  purge entries from search_history older than DAYS days.
                         Defaults to 30 days if no days specified
   --list-invites  DAYS  purge (unaccepted) list share invites older than DAYS
                         days.  Defaults to 14 days if no days specified.
   --restrictions DAYS   purge patrons restrictions expired since more than DAYS days.
                         Defaults to 30 days if no days specified.
    --all-restrictions   purge all expired patrons restrictions.
   --del-exp-selfreg  Delete expired self registration accounts
   --del-unv-selfreg  DAYS  Delete unverified self registrations older than DAYS
   --unique-holidays DAYS  Delete all unique holidays older than DAYS
   --temp-uploads     Delete temporary uploads.
   --temp-uploads-days DAYS Override the corresponding preference value.
   --uploads-missing FLAG Delete upload records for missing files when FLAG is true, count them otherwise
   --oauth-tokens     Delete expired OAuth2 tokens
   --list-corrupted-data List the corrupted data. A data is considered corrupted if the move of a row from one table to another can lead to data loss (See https://wiki.koha-community.org/wiki/DBMS_auto_increment_fix for more informations)
   --fix-corrupted-data Fix the corrupted data by assigning a new id to the rows
USAGE
    exit $_[0];
}

my $help;
my $sessions;
my $sess_days;
my $verbose;
my $zebraqueue_days;
my $mail;
my $purge_merged;
my $pImport;
my $pLogs;
my $pSearchhistory;
my $pZ3950;
my $pListShareInvites;
my $pDebarments;
my $allDebarments;
my $pExpSelfReg;
my $pUnvSelfReg;
my $fees_days;
my $special_holidays_days;
my $temp_uploads;
my $temp_uploads_days;
my $uploads_missing;
my $oauth_tokens;
my ( $list_corrupted_data, $fix_corrupted_data );

GetOptions(
    'h|help'            => \$help,
    'sessions'          => \$sessions,
    'sessdays:i'        => \$sess_days,
    'v|verbose'         => \$verbose,
    'm|mail:i'          => \$mail,
    'zebraqueue:i'      => \$zebraqueue_days,
    'merged'            => \$purge_merged,
    'import:i'          => \$pImport,
    'z3950'             => \$pZ3950,
    'logs:i'            => \$pLogs,
    'fees:i'            => \$fees_days,
    'searchhistory:i'   => \$pSearchhistory,
    'list-invites:i'    => \$pListShareInvites,
    'restrictions:i'    => \$pDebarments,
    'all-restrictions'  => \$allDebarments,
    'del-exp-selfreg'   => \$pExpSelfReg,
    'del-unv-selfreg'   => \$pUnvSelfReg,
    'unique-holidays:i' => \$special_holidays_days,
    'temp-uploads'      => \$temp_uploads,
    'temp-uploads-days:i' => \$temp_uploads_days,
    'uploads-missing:i' => \$uploads_missing,
    'oauth-tokens'      => \$oauth_tokens,
    'list-corrupted-data' => \$list_corrupted_data,
    'fix-corrupted-data'  => \$fix_corrupted_data,
) || usage(1);

# Use default values
$sessions          = 1                                    if $sess_days                  && $sess_days > 0;
$pImport           = DEFAULT_IMPORT_PURGEDAYS             if defined($pImport)           && $pImport == 0;
$pLogs             = DEFAULT_LOGS_PURGEDAYS               if defined($pLogs)             && $pLogs == 0;
$zebraqueue_days   = DEFAULT_ZEBRAQ_PURGEDAYS             if defined($zebraqueue_days)   && $zebraqueue_days == 0;
$mail              = DEFAULT_MAIL_PURGEDAYS               if defined($mail)              && $mail == 0;
$pSearchhistory    = DEFAULT_SEARCHHISTORY_PURGEDAYS      if defined($pSearchhistory)    && $pSearchhistory == 0;
$pListShareInvites = DEFAULT_SHARE_INVITATION_EXPIRY_DAYS if defined($pListShareInvites) && $pListShareInvites == 0;
$pDebarments       = DEFAULT_DEBARMENTS_PURGEDAYS         if defined($pDebarments)       && $pDebarments == 0;

if ($help) {
    usage(0);
}

unless ( $sessions
    || $zebraqueue_days
    || $mail
    || $purge_merged
    || $pImport
    || $pLogs
    || $fees_days
    || $pSearchhistory
    || $pZ3950
    || $pListShareInvites
    || $pDebarments
    || $allDebarments
    || $pExpSelfReg
    || $pUnvSelfReg
    || $special_holidays_days
    || $temp_uploads
    || defined $uploads_missing
    || $oauth_tokens
    || $list_corrupted_data
    || $fix_corrupted_data
) {
    print "You did not specify any cleanup work for the script to do.\n\n";
    usage(1);
}

if ($pDebarments && $allDebarments) {
    print "You can not specify both --restrictions and --all-restrictions.\n\n";
    usage(1);
}

cronlogaction();

my $dbh = C4::Context->dbh();
my $sth;
my $sth2;
my $count;

if ( $sessions && !$sess_days ) {
    if ($verbose) {
        print "Session purge triggered.\n";
        $sth = $dbh->prepare(q{ SELECT COUNT(*) FROM sessions });
        $sth->execute() or die $dbh->errstr;
        my @count_arr = $sth->fetchrow_array;
        print "$count_arr[0] entries will be deleted.\n";
    }
    $sth = $dbh->prepare(q{ TRUNCATE sessions });
    $sth->execute() or die $dbh->errstr;
    if ($verbose) {
        print "Done with session purge.\n";
    }
}
elsif ( $sessions && $sess_days > 0 ) {
    print "Session purge triggered with days>$sess_days.\n" if $verbose;
    RemoveOldSessions();
    print "Done with session purge with days>$sess_days.\n" if $verbose;
}

if ($zebraqueue_days) {
    $count = 0;
    print "Zebraqueue purge triggered for $zebraqueue_days days.\n" if $verbose;
    $sth = $dbh->prepare(
        q{
            SELECT id,biblio_auth_number,server,time
            FROM zebraqueue
            WHERE done=1 AND time < date_sub(curdate(), INTERVAL ? DAY)
        }
    );
    $sth->execute($zebraqueue_days) or die $dbh->errstr;
    $sth2 = $dbh->prepare(q{ DELETE FROM zebraqueue WHERE id=? });
    while ( my $record = $sth->fetchrow_hashref ) {
        $sth2->execute( $record->{id} ) or die $dbh->errstr;
        $count++;
    }
    print "$count records were deleted.\nDone with zebraqueue purge.\n" if $verbose;
}

if ($mail) {
    print "Mail queue purge triggered for $mail days.\n" if $verbose;
    $sth = $dbh->prepare(
        q{
            DELETE FROM message_queue
            WHERE time_queued < date_sub(curdate(), INTERVAL ? DAY)
        }
    );
    $sth->execute($mail) or die $dbh->errstr;
    $count = $sth->rows;
    $sth->finish;
    print "$count messages were deleted from the mail queue.\nDone with message_queue purge.\n" if $verbose;
}

if ($purge_merged) {
    print "Purging completed entries from need_merge_authorities.\n" if $verbose;
    $sth = $dbh->prepare(q{ DELETE FROM need_merge_authorities WHERE done=1 });
    $sth->execute() or die $dbh->errstr;
    print "Done with purging need_merge_authorities.\n" if $verbose;
}

if ($pImport) {
    print "Purging records from import tables.\n" if $verbose;
    PurgeImportTables();
    print "Done with purging import tables.\n" if $verbose;
}

if ($pZ3950) {
    print "Purging Z39.50 records from import tables.\n" if $verbose;
    PurgeZ3950();
    print "Done with purging Z39.50 records from import tables.\n" if $verbose;
}

if ($pLogs) {
    print "Purging records from action_logs.\n" if $verbose;
    $sth = $dbh->prepare(
        q{
            DELETE FROM action_logs
            WHERE timestamp < date_sub(curdate(), INTERVAL ? DAY)
        }
    );
    $sth->execute($pLogs) or die $dbh->errstr;
    print "Done with purging action_logs.\n" if $verbose;
}

if ($fees_days) {
    print "Purging records from accountlines.\n" if $verbose;
    purge_zero_balance_fees( $fees_days );
    print "Done purging records from accountlines.\n" if $verbose;
}

if ($pSearchhistory) {
    print "Purging records older than $pSearchhistory from search_history.\n" if $verbose;
    C4::Search::History::delete({ interval => $pSearchhistory });
    print "Done with purging search_history.\n" if $verbose;
}

if ($pListShareInvites) {
    print "Purging unaccepted list share invites older than $pListShareInvites days.\n" if $verbose;
    $sth = $dbh->prepare(
        q{
            DELETE FROM virtualshelfshares
            WHERE invitekey IS NOT NULL
            AND (sharedate + INTERVAL ? DAY) < NOW()
        }
    );
    $sth->execute($pListShareInvites);
    print "Done with purging unaccepted list share invites.\n" if $verbose;
}

if ($pDebarments) {
    print "Expired patrons restrictions purge triggered for $pDebarments days.\n" if $verbose;
    $count = PurgeDebarments($pDebarments);
    print "$count restrictions were deleted.\nDone with restrictions purge.\n" if $verbose;
}

if($allDebarments) {
    print "All expired patrons restrictions purge triggered.\n" if $verbose;
    $count = PurgeDebarments(0);
    print "$count restrictions were deleted.\nDone with all restrictions purge.\n" if $verbose;
}

if( $pExpSelfReg ) {
    DeleteExpiredSelfRegs();
}
if( $pUnvSelfReg ) {
    DeleteUnverifiedSelfRegs( $pUnvSelfReg );
}

if ($special_holidays_days) {
    DeleteSpecialHolidays( abs($special_holidays_days) );
}

if( $temp_uploads ) {
    # Delete temporary uploads, governed by a pref (unless you override)
    print "Purging temporary uploads.\n" if $verbose;
    Koha::UploadedFiles->delete_temporary({
        defined($temp_uploads_days)
            ? ( override_pref => $temp_uploads_days )
            : ()
    });
    print "Done purging temporary uploads.\n" if $verbose;
}

if( defined $uploads_missing ) {
    print "Looking for missing uploads\n" if $verbose;
    my $keep = $uploads_missing == 1 ? 0 : 1;
    my $count = Koha::UploadedFiles->delete_missing({ keep_record => $keep });
    if( $keep ) {
        print "Counted $count missing uploaded files\n";
    } else {
        print "Removed $count records for missing uploads\n";
    }
}

if ($oauth_tokens) {
    require Koha::OAuthAccessTokens;

    my $count = int Koha::OAuthAccessTokens->search({ expires => { '<=', time } })->delete;
    say "Removed $count expired OAuth2 tokens" if $verbose;
}

if ( $list_corrupted_data or $fix_corrupted_data ) {
    print "Looking for corrupted data\n" if $verbose;

    my $RaiseError = $dbh->{RaiseError};
    $dbh->{RaiseError} = 1;
    my $data = GetCorruptedData();
    if (@$data) {
        print "Problems found!\n" if $verbose;
        TABLES: for my $data (@$data) {
            my $col_name      = $data->{col_name};
            my $table         = $data->{tables}[0];
            my $deleted_table = $data->{tables}[1];
            print "\n * Tables $table/$deleted_table: ";
            print join( ', ', map { $_->{$col_name} } @{ $data->{rows} } ) . "\n";
            if ($fix_corrupted_data) {
                FixCorruptedData(
                    {
                        table         => $table,
                        deleted_table => $deleted_table,
                        col_name      => $col_name,
                        rows          => $data->{rows}
                    }
                );
            }
        }
    }
    else {
        print "Everything is clean!\n";
    }
    $dbh->{RaiseError} = $RaiseError;
}

exit(0);

sub RemoveOldSessions {
    my ( $id, $a_session, $limit, $lasttime );
    $limit = time() - 24 * 3600 * $sess_days;

    $sth = $dbh->prepare(q{ SELECT id, a_session FROM sessions });
    $sth->execute or die $dbh->errstr;
    $sth->bind_columns( \$id, \$a_session );
    $sth2  = $dbh->prepare(q{ DELETE FROM sessions WHERE id=? });
    $count = 0;

    while ( $sth->fetch ) {
        $lasttime = 0;
        if ( $a_session =~ /lasttime:\s+'?(\d+)/ ) {
            $lasttime = $1;
        }
        elsif ( $a_session =~ /(ATIME|CTIME):\s+'?(\d+)/ ) {
            $lasttime = $2;
        }
        if ( $lasttime && $lasttime < $limit ) {
            $sth2->execute($id) or die $dbh->errstr;
            $count++;
        }
    }
    if ($verbose) {
        print "$count sessions were deleted.\n";
    }
}

sub PurgeImportTables {

    #First purge import_records
    #Delete cascades to import_biblios, import_items and import_record_matches
    $sth = $dbh->prepare(
        q{
            DELETE FROM import_records
            WHERE upload_timestamp < date_sub(curdate(), INTERVAL ? DAY)
        }
    );
    $sth->execute($pImport) or die $dbh->errstr;

    # Now purge import_batches
    # Timestamp cannot be used here without care, because records are added
    # continuously to batches without updating timestamp (Z39.50 search).
    # So we only delete older empty batches.
    # This delete will therefore not have a cascading effect.
    $sth = $dbh->prepare(
        q{
            DELETE ba
            FROM import_batches ba
            LEFT JOIN import_records re ON re.import_batch_id=ba.import_batch_id
            WHERE re.import_record_id IS NULL AND
            ba.upload_timestamp < date_sub(curdate(), INTERVAL ? DAY)
        }
    );
    $sth->execute($pImport) or die $dbh->errstr;
}

sub PurgeZ3950 {
    $sth = $dbh->prepare(
        q{
            DELETE FROM import_batches
            WHERE batch_type = 'z3950'
        }
    );
    $sth->execute() or die $dbh->errstr;
}

sub PurgeDebarments {
    require Koha::Patron::Debarments;
    my $days = shift;
    $count = 0;
    $sth   = $dbh->prepare(
        q{
            SELECT borrower_debarment_id
            FROM borrower_debarments
            WHERE expiration < date_sub(curdate(), INTERVAL ? DAY)
        }
    );
    $sth->execute($days) or die $dbh->errstr;
    while ( my ($borrower_debarment_id) = $sth->fetchrow_array ) {
        Koha::Patron::Debarments::DelDebarment($borrower_debarment_id);
        $count++;
    }
    return $count;
}

sub DeleteExpiredSelfRegs {
    my $cnt= C4::Members::DeleteExpiredOpacRegistrations();
    print "Removed $cnt expired self-registered borrowers\n" if $verbose;
}

sub DeleteUnverifiedSelfRegs {
    my $cnt= C4::Members::DeleteUnverifiedOpacRegistrations( $_[0] );
    print "Removed $cnt unverified self-registrations\n" if $verbose;
}

sub DeleteSpecialHolidays {
    my ( $days ) = @_;

    my $sth = $dbh->prepare(q{
        DELETE FROM special_holidays
        WHERE DATE( CONCAT( year, '-', month, '-', day ) ) < DATE_SUB( CAST(NOW() AS DATE), INTERVAL ? DAY );
    });
    my $count = $sth->execute( $days ) + 0;
    print "Removed $count unique holidays\n" if $verbose;
}

sub FixCorruptedData {
    my ($params)      = @_;
    my $table         = $params->{table};
    my $deleted_table = $params->{deleted_table};
    my $col_name      = $params->{col_name};
    my $rows = $params->{rows} || [];
    my $schema = Koha::Database->new->schema;
    $schema->storage->txn_begin;
    my $query_max = qq|
        SELECT GREATEST(
            COALESCE( ( SELECT MAX($col_name) FROM $table         ), 0 ),
            COALESCE( ( SELECT MAX($col_name) FROM $deleted_table ), 0 )
        ) + 1 AS max;
    |;
    my ($max)     = $dbh->selectrow_array($query_max);
    my $query_fix = qq|UPDATE $table SET $col_name = ? WHERE $col_name = ?|;
    my $sth_fix   = $dbh->prepare($query_fix);
    my $everything_went_fine = 1;
    ROWS: for my $row ( @{$rows} ) {
        my $old_id = $row->{$col_name};
        print "Updating $table.$col_name=$old_id with new id $max\n";
        eval {
            $sth_fix->execute( $max, $old_id );
            if ( $table eq 'issues' ) {
                $dbh->do( q|UPDATE accountlines SET issue_id = ? WHERE issue_id = ?|, undef, $max, $old_id );
            } elsif ( $table eq 'borrowers' ) {
                $dbh->do( q|UPDATE borrower_password_recovery SET borrowernumber = ? WHERE borrowernumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE borrowers SET guarantorid = ? WHERE guarantorid= ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE notifys SET borrowernumber = ? WHERE borrowernumber = ?|, undef, $max, $old_id ); # Just in case, see bug 10021
                $dbh->do( q|UPDATE saved_sql SET borrowernumber = ? WHERE borrowernumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE search_history SET userid = ? WHERE userid = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE statistics SET borrowernumber = ? WHERE borrowernumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE aqbudgets SET budget_owner_id = ? WHERE budget_owner_id = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE aqbasket SET authorisedby = ? WHERE authorisedby = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE suggestions SET suggestedby = ? WHERE suggestedby = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE suggestions SET managedby = ? WHERE managedby = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE suggestions SET acceptedby = ? WHERE acceptedby = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE suggestions SET rejectedby = ? WHERE rejectedby = ?|, undef, $max, $old_id );
            } elsif ( $table eq 'biblio' ) {
                $dbh->do( q|UPDATE import_biblios SET matched_biblionumber = ? WHERE matched_biblionumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE oai_sets_biblios SET biblionumber = ? WHERE biblionumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE serial SET biblionumber = ? WHERE biblionumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE subscription SET biblionumber = ? WHERE biblionumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE subscriptionhistory SET biblionumber = ? WHERE biblionumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE tmp_holdsqueue SET biblionumber = ? WHERE biblionumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE suggestions SET biblionumber = ? WHERE biblionumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE linktracker SET biblionumber = ? WHERE biblionumber = ?|, undef, $max, $old_id );
                # Delete old record from index
                C4::Biblio::ModZebra( $old_id, 'recordDelete',  'biblioserver' );
                # Add/Update new record
                C4::Biblio::ModZebra( $max,    'specialUpdate', 'biblioserver' );
            } elsif ( $table eq 'items' ) {
                $dbh->do( q|UPDATE collections_tracking SET itemnumber = ? WHERE itemnumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE import_items SET itemnumber = ? WHERE itemnumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE notifys SET itemnumber = ? WHERE itemnumber = ?|, undef, $max, $old_id ); # Just in case, see bug 10021
                $dbh->do( q|UPDATE statistics SET itemnumber = ? WHERE itemnumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE tmp_holdsqueue SET itemnumber = ? WHERE itemnumber = ?|, undef, $max, $old_id );
                $dbh->do( q|UPDATE accountlines SET itemnumber = ? WHERE itemnumber = ?|, undef, $max, $old_id );
            }
        };
        if ($@) {
            print "Something went wrong, rolling back!\n";
            $schema->storage->txn_rollback;
            $everything_went_fine = 0;
            last ROWS;
        }
        $max++;
    }
    $schema->storage->txn_commit if $everything_went_fine;
}

sub GetCorruptedData {
    my $dbh     = C4::Context->dbh;
    my $patrons = $dbh->selectall_arrayref(
        q|SELECT b.borrowernumber FROM borrowers b JOIN deletedborrowers db ON b.borrowernumber=db.borrowernumber|,
        { Slice => {} }
    );
    my $biblios = $dbh->selectall_arrayref(
        q|SELECT b.biblionumber FROM biblio b JOIN deletedbiblio db ON b.biblionumber=db.biblionumber|,
        { Slice => {} }
    );
    my $biblioitems = $dbh->selectall_arrayref(
        q|SELECT b.biblioitemnumber FROM biblioitems b JOIN deletedbiblioitems db ON b.biblioitemnumber=db.biblioitemnumber|,
        { Slice => {} }
    );
    my $items = $dbh->selectall_arrayref(
        q|SELECT i.itemnumber FROM items i JOIN deleteditems di ON i.itemnumber=di.itemnumber|,
        { Slice => {} }
    );
    my $checkouts = $dbh->selectall_arrayref(
        q|SELECT i.issue_id FROM issues i JOIN old_issues oi ON i.issue_id=oi.issue_id|,
        { Slice => {} }
    );
    my $holds = $dbh->selectall_arrayref(
        q|SELECT r.reserve_id FROM reserves r JOIN old_reserves o ON r.reserve_id=o.reserve_id|,
        { Slice => {} }
    );
    return [
        (
            @$patrons
            ? {
                entity => 'patrons',
                col_name => 'borrowernumber',
                rows => $patrons,
                tables  => [ 'borrowers', 'deletedborrowers' ],
              }
            : ()
        ),
        (
            @$biblios
            ? { entity => 'biblios', col_name => 'biblionumber', rows => $biblios, tables => [ 'biblio', 'deletedbiblio' ] }
            : ()
        ),
        (
            @$biblioitems
            ? { entity => 'biblioitems', col_name => 'biblioitemnumber', rows => $biblioitems, tables => ['biblioitems', 'deletedbiblioitems'] }
            : ()
        ),
        (
            @$items ? { entity => 'items', col_name => 'itemnumber', rows => $items, tables => [ 'items', 'deleteditems' ] }
            : ()
        ),
        (
            @$checkouts
            ? { entity => 'checkouts', col_name => 'issue_id', rows => $checkouts, tables => [ 'issues', 'old_issues' ] }
            : ()
        ),
        (
            @$holds
            ? { entity => 'holds', col_name => 'reserve_id', rows => $holds, tables => [ 'reserves', 'old_reserves' ] }
            : ()
        ),
    ];
}
