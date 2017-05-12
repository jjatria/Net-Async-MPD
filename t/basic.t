use Test::More;
use Test::Warnings;

use AnyEvent::Net::MPD;

ok my $mpd = AnyEvent::Net::MPD->new, 'constructor succeeds';

done_testing();
