package FixMyStreet::Cobrand::CyclingUK;
use base 'FixMyStreet::Cobrand::FixMyStreet';

use Moo;

=item path_to_web_templates

We want to use the fixmystreet.com templates as a fallback instead of
fixmystreet-uk-councils as this cobrand is effectively a reskin of .com rather
than a cobrand for a single council.

=cut

sub path_to_web_templates {
    my $self = shift;
    return [
        FixMyStreet->path_to( 'templates/web/cyclinguk' ),
        FixMyStreet->path_to( 'templates/web/fixmystreet.com' ),
    ];
}

=item problems_restriction

This cobrand only shows reports made on it, not those from FMS.com or others.

=cut


sub problems_restriction {
    my ($self, $rs) = @_;

    my $table = ref $rs eq 'FixMyStreet::DB::ResultSet::Nearby' ? 'problem' : 'me';
    return $rs->search({
        "$table.cobrand" => "cyclinguk"
    });
}

=item problems_on_map_restriction

Same restriction on map as problems_restriction above.

=cut


sub problems_on_map_restriction {
    my ($self, $rs) = @_;
    $self->problems_restriction($rs);
}


1;
