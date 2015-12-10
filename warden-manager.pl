#!/usr/bin/perl -w

use Common;

my $redisCli = shift || '/usr/local/bin/redis-cli';
my $serviceManagerDb = shift || 11;
my $clusterName = shift || 'eu-west-1-image-server-cluster';
my $taskName = shift || 'image-server-task:11';
my $region = shift || 'eu-west-1';

my $instanceId = GetInstanceId();
my $availabilityZone = GetAvailabilityZone();

my $MAX_HEARTBEAT_AGE = 300; # 300 seconds
my $GUARD_TIME = 15;
my $ACTIVITY_PAUSE = 300;
my $SERVICE_MANAGER_PAUSE = 30;
my $CANDIDATE_EXPIRY = 30;

my %loadBalancerCache;

while(1) {
	my @zoneList = GetActiveAvailabilityZones($region);
	my %zones = map { $_ => 1 } @zoneList;

	my $attemptNormalBehaviour = 1;

	if(!defined($zones{$availabilityZone})) {
		Log("our subnet is not listed as available.\n");
		$attemptNormalBehaviour = 0;
	}

	if(KillSwitchPresent($redisCli, $serviceManagerDb, $instanceId)) {
		Log("kill switch found - removing and skipping normal behaviour.\n");
		RemoveKillSwitch($redisCli, $serviceManagerDb, $instanceId);
		$attemptNormalBehaviour = 0;
	}

	if($attemptNormalBehaviour) {
		my $candidacy = !EvaluateCurrentServiceManager($redisCli, $serviceManagerDb, \%zones, $instanceId);

		if($candidacy == 1) {
			Log("we should try and become the leader.\n");
			if(BecomeLeader($redisCli, $serviceManagerDb, $instanceId, $availabilityZone)) {
				ServiceManagerLifecycle($redisCli, $serviceManagerDb, $instanceId, $availabilityZone, $clusterName, $taskName, $region);
			}
		}
	}

	Log("sleeping for $ACTIVITY_PAUSE seconds...\n");
	sleep($ACTIVITY_PAUSE);
}

exit;

sub ServiceManagerLifecycle {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $instanceId = shift;
	my $availabilityZone = shift;
	my $clusterName = shift;
	my $taskName = shift;
	my $region = shift;

	my $continueLifecycle = 1;

	Log("starting service manage lifecycle.\n");

	while($continueLifecycle) {

		if(KillSwitchPresent($redisCli, $serviceManagerDb, $instanceId)) {
			Log("... kill switch found - removing and stopping lifecycle.\n");
			RemoveKillSwitch($redisCli, $serviceManagerDb, $instanceId);
			$continueLifecycle = 0;
		}

		my @zoneList = GetActiveAvailabilityZones($region);
		my %zones = map { $_ => 1 } @zoneList;
		if(!defined($zones{$availabilityZone})) {
			Log("... our subnet is no longer listed as available.\n");
		}

		if($continueLifecycle == 1) {
			RecordHeartbeat($redisCli, $serviceManagerDb, $instanceId, $availabilityZone);

			my $currentTrafficLevel = GetCurrentTrafficLevel($region); # maximum requests over last hour.
			my $desiredNumberOfTasks = CalculateDesiredNumberOfTasks($currentTrafficLevel);
			my $currentNumberOfTasks = GetCurrentNumberOfTasks($clusterName);

			Log("... current number of tasks = $currentNumberOfTasks.\n");
			Log("... desired number of tasks = $desiredNumberOfTasks.\n");

			if($currentNumberOfTasks < $desiredNumberOfTasks) {
				# too few tasks
				IncreaseRunningTasksBy($clusterName, $taskName, $desiredNumberOfTasks - $currentNumberOfTasks);
			} elsif ($currentNumberOfTasks > $desiredNumberOfTasks) {
				# too many tasks
				ReduceRunningTasksBy($clusterName, $taskName, $currentNumberOfTasks - $desiredNumberOfTasks);
			} else {
				# current == desired
				Log("... current number of tasks = desired number.\n");
			}

			Log("sleeping for $SERVICE_MANAGER_PAUSE seconds.\n");
			sleep($SERVICE_MANAGER_PAUSE);
		}
	}
} # ServiceManagerLifecycle

sub GetCurrentTrafficLevel {
	my $region = shift;
	Log("fetching current traffic level...\n");
	my $loadBalancerName = GetLoadBalancerForTag("elasticbeanstalk:environment-name", "dlcs-orchestration-env", $region);

	my $endTime = GetTimestamp();
	my $startTime = GetAdjustedTimestamp(60 * -60); # adjust time by -1 hour

	my $result = `aws cloudwatch get-metric-statistics --namespace AWS/ELB --metric-name RequestCount --start-time $startTime --end-time $endTime --period 3600 --statistics Maximum --dimensions Name=LoadBalancerName,Value=$loadBalancerName`;

	$result =~ s/[\r\n]//g;

	if($result =~ /\"Maximum\": (.*?),/) {
		my $trafficLevel = $1;
		Log("... traffic level is $trafficLevel\n");
		return $trafficLevel;
	}

	Log("... couldn't fetch traffic level.\n");
	return 0;
} # GetCurrentTrafficLevel

sub CalculateDesiredNumberOfTasks {
	my $currentTrafficLevel = shift;

	Log("calculating desired number of tasks for traffic level of $currentTrafficLevel.\n");

	return 5;
} # CalculateDesiredNumberOfTasks

sub RecordHeartbeat {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $instanceId = shift;
	my $availabilityZone = shift;

	my $timestamp = GetTimestamp();
	Log("recording heartbeat at $timestamp.\n");
	my $result = `$redisCli -n $serviceManagerDb hmset service-manager id $instanceId heartbeat $timestamp subnet $availabilityZone`;
	$result = `$redisCli -n $serviceManagerDb expire service-manager $MAX_HEARTBEAT_AGE`;
} # RecordHeartbeat

sub RemoveKillSwitch {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $instanceId = shift;

	my $key = $instanceId . "-kill";

	Log("removing kill switch.\n");
	my $result = `$redisCli -n $serviceManagerDb del $key`;
} #RemoveKillSwitch

sub KillSwitchPresent {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $instanceId = shift;

	my $key = $instanceId . "-kill";
	Log("checking for a kill switch...\n");
	my $result = `$redisCli -n $serviceManagerDb get $key`;

	if($result =~ /\"1\"/) {
		# found it
		Log("... found kill switch.\n");
		return 1;
	}

	Log("... no kill switch found.\n");
	return 0;
} # KillSwitchPresent

sub BecomeLeader {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $instanceId = shift;
	my $availabilityZone = shift;

	Log("announcing ourselves as a leadership candidate.\n");

	# roll dice
	my $diceValue = RollDice();

	# record instance-id on an expiring key (30 seconds)
	my $candidateKey = RecordCandidateData($redisCli, $serviceManagerDb, $instanceId);

	# record that key against the dice value in a sorted set
	RecordLeadershipChallenge($redisCli, $serviceManagerDb, $diceValue, $candidateKey);

	# wait for guard time
	Log("waiting for guard time ($GUARD_TIME seconds).\n");
	sleep($GUARD_TIME);

	# winner is the one with the highest score with a key that has not expired
	my $winnerInstanceId = GetLeadershipChallengeWinner($redisCli, $serviceManagerDb);

	if($winnerInstanceId ne $instanceId) {
		# we didn't win
		Log("... we did not win the leadership competition ($winnerInstanceId did).\n");
		return 0;
	}

	Log("... we won the leadership challenge.\n");
	return 1;
} # BecomeLeader

sub GetLeadershipChallengeWinner {
	my $redisCli = shift;
	my $serviceManagerDb = shift;

	Log("fetching leadership-challenge members.\n");

	my $result = `$redisCli -n $serviceManagerDb --csv zrevrange leadership-challenge 0 -1`;

	$result =~ s/[\"\r\n]//g;

	my @keys = split(/,/, $result);

	my $winner = "";

	foreach my $key (@keys) {
		Log("... checking $key for expiry.\n");
		$result = `$redisCli -n $serviceManagerDb get $key`;
		$result =~ s/[\r\n]//g;

		if($result =~ /nil/ || $result eq "") {
			# key could not be found
			Log("... removing dead key ($key) from leadership-challenge.\n");
			$result = `$redisCli -n $serviceManagerDb zrem leadership-challenge $key`;
			next;
		}
		if($winner eq "") {
			$winner = $key;
		}
	}

	$winner =~ /^\d+\-(.*?)$/g;

	return $1;
} # GetLeadershipChallengeWinner

sub RollDice {
	my $range = 101;

	Log("rolling dice (range = $range)\n");
	my $randomNumber = int(rand($range));

	Log("... result was $randomNumber.\n");

	if($randomNumber == 100) {
		Log("... critical hit!\n");
	}

	return $randomNumber;
} # RollDice

sub RecordCandidateData {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $instanceId = shift;

	my $key = GetTimestamp() . "-" . $instanceId; # e.g. 201509080952-i-fe10a80

	Log("recording candidate data for $instanceId with key $key.\n");
	Log("... (this will expire in $CANDIDATE_EXPIRY seconds)\n");

	my $result = `$redisCli -n $serviceManagerDb set $key $instanceId`;
	$result = `$redisCli -n $serviceManagerDb expire $key $CANDIDATE_EXPIRY`;

	return $key;
} # RecordCandidateData

sub RecordLeadershipChallenge {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $candidateScore = shift;
	my $candidateKey = shift;

	Log("recording leadership challenge for key $candidateKey with score $candidateScore.\n");

	my $result = `$redisCli -n $serviceManagerDb zadd leadership-challenge $candidateScore $candidateKey`;
} # RecordLeadershipChallenge

sub EvaluateCurrentServiceManager {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $zones = shift;
	my $instanceId = shift;

	Log("evaluating current service manager...\n");

	# get current service manager details
	# if none recorded then return false

	my $serviceManager = GetCurrentServiceManager($redisCli, $serviceManagerDb);

	if(!defined($serviceManager)) {
		# no current service manager defined so return false
		Log("... no current service manager. We can challenge.\n");
		return 0;
	}

	if($$serviceManager{"id"} eq $instanceId) {
		# that's actually us ...
		Log("... that's us. We can challenge.\n");
		return 0;
	}

	# expecting:
	# id   ($serviceManager{"id"})
	# most recent heartbeat  ($serviceManager{"heartbeat"})
	# home sub-net  ($serviceManager{"subnet"}))

	my $heartbeatAge = GetTimeDifference($$serviceManager{"heartbeat"}, GetTimestamp());
	my $serviceManagerSubnet = $$serviceManager{"subnet"};

	my $shutdownCurrentServiceManager = 0;

	if($heartbeatAge > $MAX_HEARTBEAT_AGE) {
		# heartbeat is too old
		Log("... current service manager's heartbeat is more than $MAX_HEARTBEAT_AGE seconds in the past. We can challenge.\n");
		$shutdownCurrentServiceManager = 1;
	} elsif (!defined($$zones{$serviceManagerSubnet})) {
		# service manager is on a subnet that is listed as unavailable
		# signal service-manager in the hope that it detects and shuts down
		Log("... current service manager's subnet (" . $$serviceManager{"subnet"} . ") is not listed as available. We can challenge.\n");
		$shutdownCurrentServiceManager = 1;
	} else {
		# service manager has lodged heartbeat recently enough to be okay and is on a subnet that is available
		Log("... current service manager seems healthy. No need to challenge.\n");
		return 1;
	}

	if($shutdownCurrentServiceManager == 1) {
		SignalServiceManagerToShutdown($redisCli, $serviceManagerDb, $$serviceManager{"id"});
	}

	return 0;
} # EvaluateCurrentServiceManager

sub SignalServiceManagerToShutdown {
	my $redisCli = shift;
	my $serviceManagerDb = shift;
	my $serviceManagerId = shift;

	Log("signalling current service manager to shutdown.\n");
	my $result = `$redisCli -n $serviceManagerDb set $serviceManagerId-kill 1`;

} # SignalServiceManagerToShutdown

sub GetCurrentServiceManager {
	my $redisCli = shift;
	my $serviceManagerDb = shift;

	my %serviceManager;

	Log("getting current service manager details...\n");
	my $result = `$redisCli -n $serviceManagerDb --csv hgetall service-manager`;
	$result =~ s/[\r\n]//g;

	my @fields = split(/,/, $result);

	if(scalar @fields == 1 || $result eq '') {
		# no current service-manager
		Log("... no current service manager found.\n");
		return undef;
	}

	for(my $x = 0; $x < scalar @fields - 1; $x+= 2) {
		my $key = $fields[$x];
		my $value = $fields[$x+1];
		$key =~ s/\"//g;
		$value =~ s/\"//g;
		$serviceManager{$key} = $value;
	}

	Log("... current service manager: id:" . $serviceManager{"id"} . " subnet:" . $serviceManager{"subnet"} . " heartbeat:" . $serviceManager{"heartbeat"} . "\n");

	return \%serviceManager;
} # GetCurrentServiceManager
