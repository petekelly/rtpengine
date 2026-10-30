#!/usr/bin/perl
# Copilot: Lines_Original=0; Lines_Added=82; Lines_Edited=0; Last_AI_EditUTC=2026-10-30T13:33:15Z

use strict;
use warnings;
use NGCP::Rtpengine::Test;
use NGCP::Rtpengine::AutoTest;
use Test::More;
use Time::HiRes qw(usleep);

autotest_start(qw(--config-file=none -t -1 -i 203.0.113.1
	-n 2223 -c 12345 -f -L 7 -E -u 2222)) or die;

sub sdp {
	my ($port, $out) = @_;
	my $address = $out ? '203.0.113.1' : '198.51.100.1';
	my $rtcp = $out ? "a=rtcp:PORT\n" : '';
	return "v=0
o=- 1545997027 1 IN IP4 198.51.100.1
s=tester
t=0 0
m=audio $port RTP/AVP 0 101
c=IN IP4 $address
a=rtpmap:0 PCMU/8000
a=rtpmap:101 telephone-event/8000
a=sendrecv
$rtcp";
}

sub setup_call {
	my ($a, $b) = new_call([qw(198.51.100.1 4000)], [qw(198.51.100.1 5000)]);
	my ($pa) = offer('PCI DTMF', {}, sdp(4000, 0) . "------------------\n" . sdp('PORT', 1));
	my ($pb) = answer('PCI DTMF', {}, sdp(5000, 0) . "------------------\n" . sdp('PORT', 1));
	return ($a, $b, $pa, $pb);
}

for my $delay (0, 1, 100) {
	my ($a, $b, $pa, $pb) = setup_call();
	rtpe_req('block DTMF', "PCI replacement, delay $delay",
		{ 'from-tag' => ft(), flags => ['directional'], 'DTMF-security' => 'DTMF',
			digit => 'D', 'delay-buffer' => $delay });
	for my $seq (53074 .. 53084) {
		snd($a, $pb, rtp(0, $seq, 238560 + ($seq - 53074) * 160, 0x1234, "\xff" x 160));
		rcv($b, $pa, rtpm(0, -1, -1, -1, "\xff" x 160));
	}
	# All seven packets of an unseen older event arrive after eleven newer audio packets.
	for my $i (0 .. 6) {
		my $pt = 101 | ($i == 0 ? 0x80 : 0);
		my $flags = $i >= 4 ? 0x8a : 0x0a;
		my $duration = ($i >= 4 ? 5 : $i + 1) * 160;
		snd($a, $pb, rtp($pt, 53067 + $i, 237440, 0x1234, pack('CCn', 1, $flags, $duration)));
		rcv($b, $pa, rtpm($pt, -1, -1, -1, pack('CCn', 15, $flags, $duration)));
	}
	snd($a, $pb, rtp(101, 53073, 237440, 0x1234, "\x01\x8a\x03\x20"));
	rcv($b, $pa, rtpm(101, -1, -1, -1, "\x0f\x8a\x03\x20"));
	snd($a, $pb, rtp(101, 53066, 237440, 0x1234, "\x01\x8a"));
	usleep(($delay + 20) * 1000);
	rcv_no($b);
	# The reverse leg is not secured.
	snd($b, $pa, rtp(101 | 0x80, 100, 1000, 0x5678, "\x03\x0a\x00\xa0"));
	rcv($a, $pb, rtpm(101 | 0x80, -1, -1, -1, "\x03\x0a\x00\xa0"));
}

{
	my ($a, $b, $pa, $pb) = setup_call();
	rtpe_req('unblock DTMF', 'buffer without suppression',
		{ 'from-tag' => ft(), flags => ['directional'], 'delay-buffer' => 200 });
	snd($a, $pb, rtp(101 | 0x80, 100, 1000, 0x1234, "\x01\x0a\x00\xa0"));
	usleep(20000);
	rtpe_req('block DTMF', 'activate while buffered',
		{ 'from-tag' => ft(), flags => ['directional'], 'DTMF-security' => 'DTMF',
			digit => 'D', 'delay-buffer' => 200 });
	rcv($b, $pa, rtpm(101 | 0x80, -1, -1, -1, "\x0f\x0a\x00\xa0"));

	snd($a, $pb, rtp(101, 101, 1000, 0x1234, "\x01\x0a\x01\x40"));
	usleep(20000);
	rtpe_req('unblock DTMF', 'deactivate while buffered',
		{ 'from-tag' => ft(), flags => ['directional'], 'delay-buffer' => 200 });
	# Suppression is evaluated at egress; originals are permitted only once it is off.
	rcv($b, $pa, rtpm(101, -1, -1, -1, "\x01\x0a\x01\x40"));
}

done_testing();
