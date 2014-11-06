#!/usr/bin/perl

use WebService::NFSN;
use Config::Tiny;
use Net::DNS;

my $conf = Config::Tiny->new;
$conf = $conf->read($ARGV[0] || "/etc/nfsn-update.conf") or die "Couldn't read config";

die "Not enough configs" if(!exists $conf->{_}->{username}
	or !exists $conf->{_}->{api_key}
	or !exists $conf->{_}->{RR}
	or !exists $conf->{_}->{domain});

my $IP_CMD = $conf->{_}->{ip_cmd} || "/usr/bin/ip";

my @types;
push @types, 'A' if(!exists $conf->{_}->{no_ipv4});
push @types, 'AAAA' if(!exists $conf->{_}->{no_ipv6});

my %foreign = ( A => ($conf->{_}->{ipv4_foreign} || '1/1'),
		AAAA => ($conf->{_}->{ipv6_foreign} || '1::'),
		);

my %old_addrs = get_old($conf->{_}->{RR}, $conf->{_}->{domain}, \@types);
my %new_addrs = get_new(\%foreign, \@types);

# Check if any addrs have changed
my $changed = 0;
for my $type (@types) {
	$changed = 1 if(defined $new_addrs{$type} and $old_addrs{$type} ne $new_addrs{$type});
}

# Push an update!
if($changed) {
	my $n = WebService::NFSN->new($conf->{_}->{username}, $conf->{_}->{api_key});
	my $dns = $n->dns($conf->{_}->{domain});

	for my $type (@types) {
		next if(!defined $old_addrs{$type} || !defined $new_addrs{$type});
		next if($old_addrs{$type} eq $new_addrs{$type});
		$dns->removeRR(name => $conf->{_}->{RR}, type => $type, data => "$old_addrs{$type}");
	}

	sleep 1;

	for my $type (@types) {
		next if(!defined $new_addrs{$type});
		next if($old_addrs{$type} eq $new_addrs{$type});
		$dns->addRR(name => $conf->{_}->{RR}, type => $type, data => "$new_addrs{$type}");
	}
}


sub get_new {
	my ($foreign, $types) = @_;

	my %results;
	for my $type (@{$types}) {
		$results{$type} = get_route_source($foreign->{$type});
	}

	return %results;
}

sub get_route_source {
	my $dest = shift;

	# hopefully, some day, I can poke netlink directly for this
	open(my $ip, "-|", "$IP_CMD -o route get $dest")
		or die "Failed to open ip command for $dest: $!";
	my $src;
	while(<$ip>) {
		chomp;
		my @a = split;
		# step through the fields of output looking for src
		while(my $b = shift @a) {
			if($b eq "unreachable") {
				last;
			}
			if($b eq "src") {
				$src = shift @a;
				last;
			}
		}
	}
	close($ip)
		or die "Failed to close ip command for $dest: $!";
	
	return $src;
}


sub get_old {
	my ($RR, $domain, $types) = @_;

	$RR = "$RR.$domain";
	# Look up the NS records for $domain
	my $def_res = Net::DNS::Resolver->new;
	my $ns_recs = $def_res->query($domain, 'NS');
	die "Failed to look up NS records" if(!defined $ns_recs);

	my @domain_ns;
	for my $rr ($ns_recs->answer) {
		if($rr->type eq 'NS') {
			push @domain_ns, $rr->rdstring;
		}
	}

	# Use those servers to look up the values for $RR
	my %results;
	my $ns_res = Net::DNS::Resolver->new(
		nameservers => \@domain_ns,
		recurse => 0,
		);
	for my $type (@{$types}) {
		my $recs = $ns_res->query($RR, $type);
		if(!defined $recs) {
			$results{$type} = undef;
			next;
		}
		for my $rr ($recs->answer) {
			if($rr->type eq $type) {
				die "Multiple existing $type records"
					if(exists $results{$type});
				$results{$type} = $rr->rdstring;
			}
		}
	}
	return %results;
}
