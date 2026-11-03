#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 35;

use_ok('Net::IPData');

# --- api_key is required ---
eval { Net::IPData->new() };
like($@, qr/api_key/, 'dies without api_key');

eval { Net::IPData->new(api_key => '') };
like($@, qr/api_key/, 'dies with empty api_key');

# --- default construction ---
my $ipd = Net::IPData->new(api_key => 'test_key');
isa_ok($ipd, 'Net::IPData');
is($ipd->api_key,  'test_key',                      'api_key accessor');
is($ipd->base_url, 'https://api.ipdata.co',         'default base_url');
is($ipd->timeout,  30,                               'default timeout');

# --- EU endpoint ---
my $eu = Net::IPData->new(api_key => 'test_key', eu => 1);
is($eu->base_url, 'https://eu-api.ipdata.co', 'EU base_url');

# --- custom base_url overrides eu ---
my $custom = Net::IPData->new(
    api_key  => 'test_key',
    base_url => 'https://custom.example.com/v1',
    eu       => 1,
);
is($custom->base_url, 'https://custom.example.com/v1', 'custom base_url overrides eu');

# --- custom timeout ---
my $slow = Net::IPData->new(api_key => 'test_key', timeout => 60);
is($slow->timeout, 60, 'custom timeout');

# --- trailing slash stripped ---
my $slash = Net::IPData->new(api_key => 'test_key', base_url => 'https://api.ipdata.co///');
is($slash->base_url, 'https://api.ipdata.co', 'trailing slashes stripped');

# --- URL building (internal, but verify via lookup_field argument validation) ---
eval { $ipd->lookup_field('8.8.8.8', 'invalid_field_xyz') };
like($@, qr/Invalid field/, 'rejects invalid field name');

eval { $ipd->lookup_field('', 'ip') };
like($@, qr/ip.*missing/i, 'lookup_field requires ip');

eval { $ipd->lookup_field('8.8.8.8', '') };
like($@, qr/field.*missing/i, 'lookup_field requires field');

# --- connection reuse options (defaults) ---
is($ipd->keep_alive, 1, 'keep_alive defaults to 1');
ok(!defined $ipd->keep_alive_timeout, 'keep_alive_timeout is unset by default');
isa_ok($ipd->ua, 'HTTP::Tiny', 'default user agent');
is($ipd->ua->keep_alive, 1, 'HTTP::Tiny is built with keep_alive => 1');
is($ipd->ua->timeout, 30, 'HTTP::Tiny is built with the timeout');
is($ipd->ua->agent, "Net-IPData-Perl/$Net::IPData::VERSION", 'HTTP::Tiny carries the Net-IPData-Perl user agent');
my $ssl_options = $ipd->ua->SSL_options || {};
ok(!$ssl_options->{SSL_alpn_protocols}, 'no ALPN protocols (h2) are advertised');

# --- keep_alive => 0 ---
my $no_keep_alive = Net::IPData->new(api_key => 'test_key', keep_alive => 0);
is($no_keep_alive->keep_alive, 0, 'keep_alive => 0 is stored');
is($no_keep_alive->ua->keep_alive, 0, 'HTTP::Tiny is built with keep_alive => 0');

# --- keep_alive_timeout ---
my $idle = Net::IPData->new(api_key => 'test_key', keep_alive_timeout => 60);
is($idle->keep_alive_timeout, 60, 'keep_alive_timeout is stored');
is($idle->keep_alive, 1, 'keep_alive still defaults to 1 alongside keep_alive_timeout');
SKIP: {
    skip "HTTP::Tiny $HTTP::Tiny::VERSION predates keep_alive_timeout (0.092)", 1
        unless eval { HTTP::Tiny->VERSION('0.092') };
    # The attribute HTTP::Tiny::Handle reads to decide whether a kept-alive
    # connection has sat idle for too long.
    is($idle->ua->{keep_alive_timeout}, 60, 'keep_alive_timeout reaches the HTTP::Tiny object');
}

# --- ua injection ---
{
    package My::Test::UA;

    sub new { return bless { calls => [] }, shift }

    sub get {
        my ($self, $url) = @_;
        push @{ $self->{calls} }, ['get', $url];
        return {
            status  => 200,
            success => 1,
            headers => { 'content-type' => 'application/json' },
            content => '{"ip":"8.8.8.8","city":"Mountain View"}',
        };
    }

    sub post {
        my ($self, $url, $opts) = @_;
        push @{ $self->{calls} }, ['post', $url, $opts];
        return {
            status  => 200,
            success => 1,
            headers => { 'content-type' => 'application/json' },
            content => '[{"ip":"8.8.8.8"}]',
        };
    }
}

my $mock_ua  = My::Test::UA->new;
my $injected = Net::IPData->new(api_key => 'test_key', ua => $mock_ua);
is($injected->ua, $mock_ua, 'injected ua is used as-is');
is($injected->keep_alive, 1, 'keep_alive is still recorded with an injected ua');

my $result = $injected->lookup('8.8.8.8');
is($result->{city}, 'Mountain View', 'lookup goes through the injected ua');
is($mock_ua->{calls}[0][0], 'get', 'injected ua received a GET');
is($mock_ua->{calls}[0][1], 'https://api.ipdata.co/8.8.8.8?api-key=test_key', 'injected ua received the lookup URL');

$injected->bulk(['8.8.8.8']);
is($mock_ua->{calls}[1][0], 'post', 'bulk goes through the injected ua as a POST');
is($mock_ua->{calls}[1][2]{content}, '["8.8.8.8"]', 'bulk body is the JSON array of IPs');

eval { Net::IPData->new(api_key => 'test_key', ua => 'not an object') };
like($@, qr/"ua"/, 'rejects a ua that is not an object');

eval { Net::IPData->new(api_key => 'test_key', ua => {}) };
like($@, qr/"ua"/, 'rejects an unblessed ua');
