package FixMyStreet::Cobrand::Bexley::Waste;

use Moo::Role;

use Integrations::Whitespace;
use DateTime;
use DateTime::Format::W3CDTF;
use DBI;
use FixMyStreet;
use FixMyStreet::Template;
use Sort::Key::Natural qw(natkeysort_inplace);

has 'whitespace' => (
    is => 'lazy',
    default => sub { Integrations::Whitespace->new(%{shift->feature('whitespace')}) },
);

sub postcode_database_file {
    FixMyStreet->path_to('../data/bexley-ww-postcodes.sqlite');
}

sub bin_addresses_for_postcode {
    my ($self, $postcode) = @_;

    return [] unless -e postcode_database_file();

    my $db = DBI->connect( 'dbi:SQLite:dbname=' . postcode_database_file(),
        undef, undef )
        or return [];

    # Remove whitespaces, make sure uppercase
    $postcode =~ s/ //g;
    $postcode = uc $postcode;

    my $addresses = $db->selectall_arrayref(
        <<SQL,
   SELECT p.uprn uprn,
          p.usrn usrn,

          pao_start_number,
          pao_start_suffix,
          pao_end_number,
          pao_end_suffix,
          pao_text,

          sao_start_number,
          sao_start_suffix,
          sao_end_number,
          sao_end_suffix,
          sao_text,

          street_descriptor,
          locality_name,
          town_name,

          parent_uprn
     FROM postcodes p
     JOIN street_descriptors sd
       ON sd.usrn = p.usrn
     LEFT OUTER JOIN child_uprns cu
       ON cu.uprn = p.uprn
    WHERE p.postcode = ?
      AND p.uprn NOT IN (
        SELECT parent_uprn FROM child_uprns
      )
SQL
        { Slice => {} },
        $postcode,
    );

    my @data =
        map {
            my $address_string = _build_address_string($_);
            {
                value => $_->{uprn},
                label => FixMyStreet::Template::title( $address_string )
            };
        } sort _sort_addresses @$addresses;

    return \@data;
}

sub _sort_addresses {
    ( $a->{pao_start_number} // 0 ) <=> ( $b->{pao_start_number} // 0 )
    or
    ( $a->{pao_start_suffix} // '' ) cmp ( $b->{pao_start_suffix} // '' )
    or
    ( $a->{pao_text} // '' ) cmp ( $b->{pao_text} // '' )
    or
    ( $a->{sao_start_number} // 0 ) <=> ( $b->{sao_start_number} // 0 )
    or
    ( $a->{sao_start_suffix} // '' ) cmp ( $b->{sao_start_suffix} // '' )
    or
    ( $a->{sao_text} // '' ) cmp ( $b->{sao_text} // '' )
}

sub _build_address_string {
    my $row = shift;

    my $sao;
    if ( $row->{parent_uprn} ) {
        $sao = _join_extended(
            ' ',
            $row->{sao_text},
            _join_extended(
                '-',
                _join_extended(
                    '', $row->{sao_start_number},
                    $row->{sao_start_suffix},
                ),
                _join_extended(
                    '',
                    $row->{sao_end_number},
                    $row->{sao_end_suffix},
                ),
            ),
        );
    }

    my $pao = _join_extended(
        ' ',
        $row->{pao_text},
        _join_extended(
            '-',
            _join_extended(
                '',
                $row->{pao_start_number},
                $row->{pao_start_suffix},
            ),
            _join_extended(
                '',
                $row->{pao_end_number},
                $row->{pao_end_suffix},
            ),
        ),
    );

    return _join_extended(
        ', ',
        _join_extended( ' ', $sao, $pao, $row->{street_descriptor} ),
        $row->{locality_name},
        $row->{town_name},
    );
}

# Only joins strings that are true / non-empty
sub _join_extended {
    my ( $sep, @strings ) = @_;

    my @strings_true_only;
    for (@strings) {
        push @strings_true_only, $_ if $_;
    }

    return join $sep, @strings_true_only;
}

sub look_up_property {
    my ( $self, $uprn ) = @_;

    my $site = $self->whitespace->GetSiteInfo($uprn);

    # We need to call GetAccountSiteID to get parent UPRN
    my %parent_property;
    if ( my $site_parent_id = $site->{Site}{SiteParentID} ) {
        my $parent_data = $self->whitespace->GetAccountSiteID($site_parent_id);
        %parent_property = (
            parent_property => {
                # NOTE 'AccountSiteUPRN' returned from GetSiteInfo,      but
                #      'AccountSiteUprn' returned from GetAccountSiteID
                id =>   $parent_data->{AccountSiteUprn},
                uprn => $parent_data->{AccountSiteUprn},
            }
        );
    }

    return {
        # 'id' is same as 'uprn' for Bexley, but since the wider wasteworks code
        # (e.g. FixMyStreet/App/Controller/Waste.pm) calls 'id' in some cases
        # and 'uprn' in others, we set both here
        id => $site->{AccountSiteUPRN},
        uprn => $site->{AccountSiteUPRN},
        address => FixMyStreet::Template::title($site->{Site}->{SiteShortAddress}),
        latitude => $site->{Site}->{SiteLatitude},
        longitude => $site->{Site}->{SiteLongitude},

        %parent_property,
    };
}

sub bin_services_for_address {
    my $self = shift;
    my $property = shift;

    my $site_services = $self->whitespace->GetSiteCollections($property->{uprn});

    # Get parent property services if no services found
    $site_services = $self->whitespace->GetSiteCollections(
        $property->{parent_property}{uprn} )
        if !@{ $site_services // [] }
        && $property->{parent_property};

    # TODO Call these in parallel
    $property->{missed_collection_reports}
        = $self->_missed_collection_reports($property);
    $property->{recent_collections} = $self->_recent_collections($property);
    my ($property_logs, $street_logs) = $self->_in_cab_logs($property);

    $property->{red_tags} = $property_logs;
    $property->{service_updates} = $street_logs;
    my %round_exceptions = map { $_->{round} => 1 } @$property_logs;
    $property->{round_exceptions} = \%round_exceptions;

    # Set certain things outside of services loop
    my $containers = $self->_containers($property);
    my $now_dt = DateTime->now->set_time_zone( FixMyStreet->local_time_zone );

    my @site_services_filtered;

    for my $service (@$site_services) {
        next if !$service->{NextCollectionDate};

        my $next_dt = eval {
            DateTime::Format::W3CDTF->parse_datetime(
                $service->{NextCollectionDate} );
        };
        if ($@) {
            warn $@;
            next;
        }

        my $from_dt = eval {
            DateTime::Format::W3CDTF->parse_datetime(
                $service->{SiteServiceValidFrom} );
        };
        if ($@) {
            warn $@;
            next;
        }
        next if $now_dt < $from_dt;

        # 0001-01-01T00:00:00 seems to represent an undefined date
        if ( $service->{SiteServiceValidTo} ne '0001-01-01T00:00:00' ) {
            my $to_dt = eval {
                DateTime::Format::W3CDTF->parse_datetime(
                    $service->{SiteServiceValidTo} );
            };
            if ($@) {
                warn $@;
                next;
            }
            next if $now_dt > $to_dt;
        }

        my $containers = $self->_containers($property);
        if (!$self->{c}->stash->{calendar_link} && $service->{RoundSchedule} =~ /(Wk \d+)/) {
            my ($id) = $service->{RoundSchedule} =~ /(Wk \d+)/;
            $id =~ s/\s+/-/;
            my $links = $self->{c}->cobrand->feature('waste_calendar_links');
            $self->{c}->stash->{calendar_link} = $links->{$id};
        }
        my ($round) = split / /, $service->{RoundSchedule};

        my $filtered_service = {
            id             => $service->{SiteServiceID},
            service_id     => $service->{ServiceItemName},
            service_name   => $containers->{ $service->{ServiceItemName} },
            round_schedule => $service->{RoundSchedule},
            round          => $round,
            next           => {
                date    => $service->{NextCollectionDate},
                ordinal => ordinal( $next_dt->day ),
                changed => 0,
                is_today => $now_dt->ymd eq $next_dt->ymd,
            },
            assisted_collection => $service->{ServiceName} && $service->{ServiceName} eq 'Assisted Collection' ? 1 : 0,
        };

        # Get the last collection date from recent collections
        my $last_dt = $property->{recent_collections}{ $service->{RoundSchedule} };

        if ($last_dt) {
            $filtered_service->{last} = {
                date    => $last_dt,
                ordinal => ordinal( $last_dt->day ),
            };
        }

        $filtered_service->{report_open}
            = $property->{missed_collection_reports}{ $filtered_service->{service_id} } ? 1 : 0;

        $filtered_service->{report_allowed}
            = $self->can_report_missed( $property, $filtered_service );

        $filtered_service->{report_locked_out}
            = $property->{round_exceptions}{ $filtered_service->{round} } ? 1 : 0;

        push @site_services_filtered, $filtered_service;
    }

    @site_services_filtered = $self->_remove_service_if_assisted_exists(@site_services_filtered);
    @site_services_filtered = $self->service_sort(@site_services_filtered);

    return \@site_services_filtered;
}

=head2 _remove_service_if_assisted_exists

Whitespace returns a standard bin service alongside an assisted collection service where
an assisted collection is in place.

This results in a duplication of bin services on the bin page so, if there is an assisted collection
for a service, we will use that and remove the standard service it corresponds to.

In case there is no corresponding assisted collection for a service we will show the standard
collection for that service.

=cut

sub _remove_service_if_assisted_exists {
    my ($self, @services) = @_;

    my %service_by_service_id = map { $_->{service_id} => $_ } grep { !$_->{assisted_collection} } @services;
    %service_by_service_id = (%service_by_service_id, map { $_->{service_id} => $_ } grep { $_->{assisted_collection} } @services);

    return values %service_by_service_id;
}


# Returns hashref of 'ServiceItemName's (FO-140, GA-140, etc.) that have
# open missed collection reports against them on the given property
sub _missed_collection_reports {
    my ( $self, $property ) = @_;

    # If property has parent, use that instead
    my $uprn
        = $property->{parent_property}
        ? $property->{parent_property}{uprn}
        : $property->{uprn};

    my $worksheets = $self->whitespace->GetSiteWorksheets($uprn);

    my %missed_collection_reports;
    for my $ws (@$worksheets) {
        if (   $ws->{WorksheetStatusName} eq 'Open'
            && $ws->{WorksheetSubject} =~ /^Missed/ )
        {
            for ( @{  $self->whitespace->GetWorksheetDetailServiceItems(
                        $ws->{WorksheetID} ) } )
            {
                $missed_collection_reports{ $_->{ServiceItemName} } = 1;
            }
        }
    }

    return \%missed_collection_reports;
}

# Returns a hash of recent collections, mapping Round + Schedule to collection
# date
sub _recent_collections {
    my ( $self, $property ) = @_;

    # Get collections for the last 21 days
    my $dt_today = DateTime->today( time_zone => FixMyStreet->local_time_zone );
    my $dt_from = $dt_today->clone->subtract( days => 21 );

    # TODO GetCollectionByUprnAndDatePlus would be preferable as it supports
    # an end date, but Bexley's live API does not seem to support it. So we
    # have to filter out future dates below.
    my $collections = $self->whitespace->GetCollectionByUprnAndDate(
        $property->{uprn},
        $dt_from->stringify,
    );

    # Collection dates are in 'dd/mm/yyyy hh:mm:ss' format.
    my $parser = DateTime::Format::Strptime->new( pattern => '%d/%m/%Y %T' );
    my %recent_collections;
    for (@$collections) {
        my $dt = $parser->parse_datetime( $_->{Date} );

        # Today's collections may not have happened yet, and we don't want any future collections.
        next if $dt->truncate( to => 'day' ) >= $dt_today;

        # Concatenate Round and Schedule, to be matched against a service's
        # RoundSchedule later
        my $round_schedule = $_->{Round} . ' ' . $_->{Schedule};

        # Check for existing date and use the most recent
        if ( my $existing = $recent_collections{ $round_schedule } ) {
            $dt = $dt > $existing ? $dt : $existing;
        }

        $recent_collections{ $round_schedule } = $dt;
    }

    return \%recent_collections;
}

# Returns a hashref of recent in-cab logs for the property, split by USRN and
# UPRN
sub _in_cab_logs {
    my ( $self, $property ) = @_;

    # Logs are recorded against parent properties, not children
    $property = $property->{parent_property} if $property->{parent_property};

    my $dt_from = $self->_subtract_working_days(3);
    my $cab_logs = $self->whitespace->GetInCabLogsByUprn(
        $property->{uprn},
        $dt_from->stringify,
    );

    my @property_logs;
    my @street_logs;

    return ( \@property_logs, \@street_logs ) unless $cab_logs;

    for (@$cab_logs) {
        next if !$_->{Reason} || $_->{Reason} eq 'N/A'; # Skip non-exceptional logs

        my $logdate = DateTime::Format::Strptime->new( pattern => '%Y-%m-%dT%H:%M:%S' )->parse_datetime( $_->{LogDate} );

        if ( $_->{Uprn} ) {
            push @property_logs, {
                uprn   => $_->{Uprn},
                round  => $_->{RoundCode},
                reason => $_->{Reason},
                date   => $logdate,
                ordinal => ordinal( $logdate->day ),
            };
        } else {
            push @street_logs, {
                round  => $_->{RoundCode},
                reason => $_->{Reason},
                date   => $logdate,
                ordinal => ordinal( $logdate->day ),
            };
        }
    }

    return ( \@property_logs, \@street_logs );
}

sub can_report_missed {
    my ( $self, $property, $service ) = @_;

    # Cannot make a report if there is already an open one for this service
    return 0 if $property->{missed_collection_reports}{ $service->{service_id} };

    # Need to be within 3 working days of the last collection
    my $last_dt = $property->{recent_collections}{ $service->{round_schedule} };
    return 0 unless $last_dt && $self->within_working_days($last_dt, 3);

    # Can't make a report if an exception has been logged for the service's round
    return 0 if $property->{round_exceptions}{ $service->{round} };

    return 1;
}

# Bexley want services to be ordered by next collection date.
# Sub-order by service name for consistent display.
sub service_sort {
    my ( $self, @services ) = @_;

    return sort {
            $a->{next}{date} cmp $b->{next}{date}
        ||  $a->{service_name} cmp $b->{service_name}
    } @services;
}

sub bin_future_collections {
    my $self = shift;

    my $services = $self->{c}->stash->{service_data};
    return [] unless $services;

    # There may be more than one service associated with a round
    my %srv_for_round;
    for (@$services) {
        push @{ $srv_for_round{ $_->{round_schedule} } }, $_;
    }

    # TODO GetCollectionByUprnAndDatePlus would be preferable as it supports
    # an end date, so we could just do a single search for the whole year. But
    # Bexley's live API does not seem to support it. So we have to use
    # several calls to GetCollectionByUprnAndDate instead, which only returns
    # a month's worth of data.
    my $year = 1900 + (localtime)[5];
    my @rounds;
    for my $month ( 1 .. 12 ) {
        push @rounds, @{ $self->whitespace->GetCollectionByUprnAndDate(
            $self->{c}->stash->{property}{uprn},
            "$year-$month-01T00:00:00",
        ) };
    }
    return [] unless @rounds;

    # Dates need to be converted from 'dd/mm/yyyy hh:mm:ss' format
    my $parser = DateTime::Format::Strptime->new( pattern => '%d/%m/%Y %T' );

    my %seen_rnd_schedule_date;
    my @events;
    for my $rnd ( @rounds ) {
        # There is a possibility that in our multiple calls to
        # GetCollectionByUprnAndDate we have picked up duplicate data (e.g.
        # the search from June 1st may have returned data from the beginning
        # of July too). So we need to dedupe.
        my $rnd_schedule = $rnd->{Round} . ' ' . $rnd->{Schedule};
        my $rnd_schedule_date = $rnd_schedule . ' ' . $rnd->{Date};

        next if $seen_rnd_schedule_date{$rnd_schedule_date};

        # Try to match Round-Schedule against services
        my $srv = $srv_for_round{$rnd_schedule};
        next unless $srv;

        my $dt = $parser->parse_datetime( $rnd->{Date} );

        for (@$srv) {
            push @events, {
                date    => $dt,
                desc    => '',
                summary => $_->{service_name},
            };
        }

        $seen_rnd_schedule_date{$rnd_schedule_date} = 1;
    }

    return \@events;
}

sub image_for_unit {
    my ( $self, $unit ) = @_;

    my $property = $self->{c}->stash->{property};

    my $is_communal = $property->{parent_property};

    my $images = {
        'FO-140'   => 'communal-food-wheeled-bin',     # Food 140 ltr Bin
        'FO-23'    => 'food-waste',                    # Food 23 ltr Caddy
        'GA-140'   => 'garden-waste-brown-bin',        # Garden 140 ltr Bin
        'GA-240'   => 'garden-waste-brown-bin',        # Garden 240 ltr Bin
        'GL-660'   => 'green-euro-bin',                # Glass 660 ltr Bin
        'GL-1100'  => 'green-euro-bin',                # Glass 1100 ltr Bin
        'GL-1280'  => 'green-euro-bin',                # Glass 1280 ltr Bin
        'GL-55'    => 'recycle-black-box',             # Glass 55 ltr Box
        'MDR-SACK' => 'recycle-bag',                   # Mixed Dry Recycling Sack
        'PC-180'   => 'recycling-bin-blue-lid',        # Paper & card 180 ltr wheeled bin
        'PC-55'    => 'blue-recycling-box',            # Paper & card 55 ltr box
        'PA-1100'  => 'communal-blue-euro',            # Paper & Cardboard & Cardbaord 1100 ltr Bin
        'PA-1280'  => 'communal-blue-euro',            # Paper & Cardboard 1280 ltr Bin
        'PA-140'   => 'communal-blue-euro',            # Paper & Cardboard 140 ltr Bin
        'PA-240'   => 'communal-blue-euro',            # Paper & Cardboard 240 ltr Bin
        'PA-55'    => 'recycle-green-box',             # Paper & Cardboard 55 ltr Box
        'PA-660'   => 'communal-blue-euro',            # Paper & Cardboard 660 ltr Bin
        'PA-940'   => 'communal-blue-euro',            # Paper & Cardboard 940 ltr Bin
        'PL-1100'  => 'plastics-wheeled-bin',          # Plastic 1100 ltr Bin
        'PL-1280'  => 'plastics-wheeled-bin',          # Plastic 1280 ltr Bin
        'PL-140'   => 'plastics-wheeled-bin',          # Plastic 140 ltr Bin
        'PL-55'    => 'recycle-maroon-box',            # Plastic 55 ltr Box
        'PL-660'   => 'plastics-wheeled-bin',          # Plastic 660 ltr Bin
        'PL-940'   => 'plastics-wheeled-bin',          # Plastic 940 ltr Bin
        'PG-1100'  => 'plastics-wheeled-bin',          # Plastics & glass 1100 ltr euro bin
        'PG-1280'  => 'plastics-wheeled-bin',          # Plastics & glass 1280 ltr euro bin
        'PG-360'   => 'plastics-wheeled-bin',          # Plastics & glass 360 ltr wheeled bin
        'PG-55'    => 'white-recycling-box',           # Plastics & glass 55 ltr box
        'PG-660'   => 'plastics-wheeled-bin',          # Plastics & glass 660 ltr euro bin
        'PG-940'   => 'plastics-wheeled-bin',          # Plastics & glass 940 ltr chamberlain bin
        'RES-1100' => 'non-recyclable-wheeled-bin',    # Residual 1100 ltr bin
        'RES-1280' => 'non-recyclable-wheeled-bin',    # Residual 1280 ltr bin
        'RES-140'  => 'non-recyclable-wheeled-bin',    # Residual 140 ltr bin
        'RES-180'  => 'general-waste-green-bin',       # Residual 180 ltr bin
        'RES-660'  => 'non-recyclable-wheeled-bin',    # Residual 660 ltr bin
        'RES-720'  => 'non-recyclable-wheeled-bin',    # Residual 720 ltr bin
        'RES-940'  => 'non-recyclable-wheeled-bin',    # Residual 940 ltr bin
        'RES-CHAM' => 'non-recyclable-wheeled-bin',    # Residual Chamberlain
        'RES-DBIN' => 'non-recyclable-wheeled-bin',    # Residual Dustbin
        'RES-SACK' => 'black-non-recyclable-bag',      # Residual Sack

        # Plastics & glass 240 ltr wheeled bin
        'PG-240' => (
            $is_communal
            ? 'plastics-wheeled-bin'
            : 'recycling-bin-white-lid'
        ),
        # Residual 240 ltr bin
        'RES-240'  => (
            $is_communal
            ? 'non-recyclable-wheeled-bin'
            : 'general-waste-green-bin'
        ),
    };

    my $service_id = $unit->{service_id};

    return '/i/waste-containers/bexley/' . $images->{$service_id};
}

sub bin_day_format { '%A, %-d~~~ %B %Y' }

# TODO This logic is copypasted across multiple files; get it into one place
my %irregulars = ( 1 => 'st', 2 => 'nd', 3 => 'rd', 11 => 'th', 12 => 'th', 13 => 'th');
sub ordinal {
    my $n = shift;
    $irregulars{$n % 100} || $irregulars{$n % 10} || 'th';
}

sub _containers {
    my ( $self, $property ) = @_;

    my $is_communal = $property->{parent_property};

    return {
        'FO-140'   => 'Communal Food Bin',
        'FO-23'    => 'Brown Caddy',
        'GA-140'   => 'Brown Wheelie Bin',
        'GA-240'   => 'Brown Wheelie Bin',
        'GL-1100'  => 'Green Recycling Bin',
        'GL-1280'  => 'Green Recycling Bin',
        'GL-55'    => 'Black Recycling Box',
        'MDR-SACK' => 'Clear Sack(s)',
        'PC-180'   => 'Blue Lidded Wheelie Bin',
        'PC-55'    => 'Blue Recycling Box',
        'PA-1100'  => 'Blue Recycling Bin',
        'PA-1280'  => 'Blue Recycling Bin',
        'PA-140'   => 'Blue Recycling Bin',
        'PA-240'   => 'Blue Recycling Bin',
        'PA-55'    => 'Green Recycling Box',
        'PA-660'   => 'Blue Recycling Bin',
        'PA-940'   => 'Blue Recycling Bin',
        'PL-1100'  => 'White / Silver Recycling Bin',
        'PL-1280'  => 'White / Silver Recycling Bin',
        'PL-140'   => 'White / Silver Recycling Bin',
        'PL-55'    => 'Maroon Recycling Box',
        'PL-660'   => 'White / Silver Recycling Bin',
        'PL-940'   => 'White / Silver Recycling Bin',
        'PG-1100'  => 'White / Silver Recycling Bin',
        'PG-1280'  => 'White / Silver Recycling Bin',
        'PG-240' => ( $is_communal
            ? 'White / Silver Recycling Bin'
            : 'White Lidded Wheelie Bin' ),
        'PG-360'   => 'White / Silver Recycling Bin',
        'PG-55'    => 'White Recycling Box',
        'PG-660'   => 'White / Silver Recycling Bin',
        'PG-940'   => 'White / Silver Recycling Bin',
        'RES-1100' => 'Communal Refuse Bin(s)',
        'RES-1280' => 'Communal Refuse Bin(s)',
        'RES-140'  => 'Communal Refuse Bin(s)',
        'RES-180'  => 'Green Wheelie Bin',
        'RES-240' => ( $is_communal
            ? 'Communal Refuse Bin(s)'
            : 'Green Wheelie bin' ),
        'RES-660'  => 'Communal Refuse Bin(s)',
        'RES-720'  => 'Communal Refuse Bin(s)',
        'RES-940'  => 'Communal Refuse Bin(s)',
        'RES-CHAM' => 'Communal Refuse Bin(s)',
        'RES-DBIN' => 'Communal Refuse Bin(s)',
        'RES-SACK' => 'Green Wheelie Bin',
    };
}

# Weekends and bank holidays are not counted as working days
sub _subtract_working_days {
    my ( $self, $day_count, $dt ) = @_;

    # Default to today
    $dt = DateTime->today( time_zone => FixMyStreet->local_time_zone )
        unless $dt;

    my $wd = FixMyStreet::WorkingDays->new(
        public_holidays => FixMyStreet::Cobrand::UK::public_holidays() );

    return $wd->sub_days( $dt, $day_count );
}

sub within_working_days {
    my ($self, $dt, $days, $future) = @_;
    my $wd = FixMyStreet::WorkingDays->new(public_holidays => FixMyStreet::Cobrand::UK::public_holidays());
    $dt = $wd->add_days($dt, $days)->ymd;
    my $today = DateTime->now->set_time_zone(FixMyStreet->local_time_zone)->ymd;
    if ( $future ) {
        return $today ge $dt;
    } else {
        return $today le $dt;
    }
}

sub waste_munge_report_data {
    my ($self, $id, $data) = @_;

    my $c = $self->{c};

    my $address = $c->stash->{property}->{address};
    my $service = $c->stash->{services}{$id}{service_name};
    $data->{title} = "Report missed $service";
    $data->{detail} = "$data->{title}\n\n$address";
    $c->set_param('service_id', $id);
}

sub waste_munge_report_form_fields {
    my ($self, $field_list) = @_;

    push @$field_list, "extra_detail" => {
        type => 'Text',
        widget => 'Textarea',
        label => 'Please supply any additional information such as the location of the bin.',
        maxlength => 1_000,
        messages => {
            text_maxlength => 'Please use 1000 characters or less for additional information.',
        },
    };
}

1;
