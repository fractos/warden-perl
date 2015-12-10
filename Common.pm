sub Log {
	my $message = shift;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();

	printf("%d/%02d/%02d %02d:%02d:%02d %s", $year, $mon, $mday, $hour, $min, $sec, $message);
} # Log

sub GetTimeDifference {
	my $time1 = shift;
	my $time2 = shift;

	return abs($time1 - $time2);
} # GetTimeDifference

sub GetTimestamp {
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime(time());
	return sprintf("%d%02d%02d%02d%02d%02d", ($year + 1900), ($mon + 1), $mday, $hour, $min, $sec);
} # GetTimestamp

sub GetAdjustedTimestamp {
	my $secondsToAdjust = shift;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime(time() + $secondsToAdjust);
	return sprintf("%d%02d%02d%02d%02d%02d", ($year + 1900), ($mon + 1), $mday, $hour, $min, $sec);
} # GetAdjustedTimestamp

sub GetInstanceId {
	Log("getting instance id...\n");
	my $instanceId = `wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`;
	$instanceId =~ s/[\r\n]//g;
	Log("... instance id = $instanceId\n");
	return $instanceId;
} # GetInstanceId

sub GetCurrentNumberOfTasks {
	my $clusterName = shift;

	Log("getting current number of tasks across cluster...\n");

	my $result = `aws ecs describe-clusters --clusters $clusterName`;

	$result =~ /.*?\"runningTasksCount\"\: (\d+)\,/;
	my $runningTasks = $1;

	$result =~ /.*?\"pendingTasksCount\"\: (\d+)\,/;
	my $pendingTasks = $1;

	my $currentNumberOfTasks = $runningTasks + $pendingTasks;

	Log("... there are $currentNumberOfTasks tasks (pending: $pendingTasks + running: $runningTasks) currently running.\n");

	return $currentNumberOfTasks;
} # GetCurrentNumberOfTasks

sub ReduceRunningTasksBy {
	my $clusterName = shift;
	my $taskName = shift;
	my $amount = shift;
	Log("reducing running tasks ($taskName) on $clusterName by $amount.\n");

	my @taskIDs = GetCurrentTaskIDs($clusterName, $taskName);

	Log("... found " . scalar @taskIDs . " task IDs.\n");

	if(scalar @taskIDs < $amount) {
		Log("... too few task IDs found to honour reduction request.\n");
		Log("(might be indicative of another active service manager).\n");
		return;
	}

	for(my $x = 0; $x < $amount; $x++) {
		Log("... stopping task with ID " . $taskIDs[$x] . ".\n");
		my $result = `aws ecs stop-task --cluster $clusterName --task $taskIDs[$x]`;
	}

} # ReduceRunningTasksBy

sub GetCurrentTaskIDs {
	my $clusterName = shift;
	my $taskName = shift;

	$taskName =~ s/^(.*?)\:\d+$/$1/;

	Log("getting current task IDs on cluster $clusterName matching task name $taskName...\n");

	my $result = `aws ecs list-tasks --cluster $clusterName`;

	$result =~ s/[\r\n]//g;

	my @taskIDs;

	while($result =~ /\"arn\:aws\:ecs\:.*?task\/(.*?)\"/g) {
		my $candidateTaskID = $1;

		Log("... checking task $candidateTaskID.\n");

		my $taskDescriptionResult = `aws ecs describe-tasks --cluster $clusterName --tasks $candidateTaskID`;
		$taskDescriptionResult =~ s/[\r\n]//g;
		if($taskDescriptionResult =~ /\"name\"\: \"$taskName\"/) {
			Log("... task $candidateTaskID is running $taskName.\n");
			push @taskIDs, $candidateTaskID;
		} else {
			Log("... task $candidateTaskID is not running $taskName.\n");
		}
	}

	Log("... found tasks with IDs (" . join(",", @taskIDs) . ").\n");

	return @taskIDs;
} # GetCurrentTaskIDs

sub IncreaseRunningTasksBy {
	my $clusterName = shift;
	my $taskName = shift;
	my $amount = shift;
	Log("increasing running tasks ($taskName) on $clusterName by $amount.\n");

	my $result = `aws ecs run-task --cluster $clusterName --task-definition $taskName --count $amount`;
} # IncreaseRunningTasksBy

sub GetLoadBalancerForTag {
	my $tagKey = shift;
	my $tagValue = shift;
	my $region = shift;

	Log("fetching load balancer that matches tag: $tagKey=$tagValue\n");

	if(defined($loadBalancerCache{$tagValue})) {
		Log("... found in cache (" . $loadBalancerCache{$tagValue} . ")\n");
		return $loadBalancerCache{$tagValue};
	}

	my $result = `aws elb describe-load-balancers --region $region`;

	my @loadBalancerNames;
	while($result =~ /\"LoadBalancerName\": \"(.*?)\"/g) {
		push @loadBalancerNames, $1;
	}

	foreach my $loadBalancerName (@loadBalancerNames) {
		Log("... getting tags for load balancer $loadBalancerName.\n");
		$result = `aws elb describe-tags --load-balancer-name $loadBalancerName`;

		$result =~ s/[\r\n]//g;

		if($result =~ /\"Value\": \"$tagValue\",\s+\"Key\": \"$tagKey\"/) {
			Log("... that's our dog.\n");
			$loadBalancerCache{$tagValue} = $loadBalancerName;
			return $loadBalancerName;
		}

		Log("... couldn't find a matching load balancer.\n");
		return "";
	}
} # GetLoadBalancerForTag

sub GetInstancePrivateDnsNameByTag {
	my $tagKey = shift;
	my $tagValue = shift;

	my $result = `aws ec2 describe-instances --filter "Name=tag:$tagKey,Values=$tagValue"`;
	$result =~ /.*?\"PrivateDnsName\"\: \"(.*?)\"/g;
	return $1;
} # GetInstancePrivateDnsNameByTag

sub GetInstancePrivateIPByTag {
	my $tagKey = shift;
	my $tagValue = shift;

	my $result = `aws ec2 describe-instances --filter "Name=tag:$tagKey,Values=$tagValue"`;
	$result =~ /.*?\"PrivateIpAddress\"\: \"(.*?)\"/g;
	return $1;
} # GetInstancePrivateIPByTag

sub GetDefaultSecurityGroupID {
	my $result = `aws ec2 describe-security-groups --filters Name=group-name,Values=default`;
	$result =~ s/[\r\n]//g;
	$result =~ /.*?\"OwnerId\"\:.*?\"GroupId\"\: \"(sg\-.*?)\"/g;
	return $1;
} # GetDefaultSecurityGroupID

sub GetSubnetIds {
	my $result = `aws ec2 describe-subnets`;

	my @subnets;

	Log("getting list of subnet IDs...\n");

	while($result =~ /.*?\"SubnetId\"\: \"(.*?)\"/g) {
		push(@subnets, $1);
	}

	return \@subnets;
} # GetSubnetIds

sub GetVPCId {
	my $result = `aws ec2 describe-vpcs --filters Name=isDefault,Values=true`;
	$result =~ /.*?\"VpcId\"\: \"(.*?)\"/g;
	return $1;
} # GetVPCId

sub GetRegion {
	Log("getting region (by getting availability zone)...\n");
	my $result = GetAvailabilityZone();
	$result =~ s/[a-z]$//;
	return $result;
} # GetRegion

sub GetAvailabilityZone {
	Log("getting availability zone...\n");
	my $availabilityZone = `wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone`;
	$availabilityZone =~ s/[\r\n]//g;
	Log("... availability zone = $availabilityZone\n");
	return $availabilityZone;
} # GetAvailabilityZone

sub GetActiveAvailabilityZones {
	my $region = shift;
	Log("getting active availability zones...\n");
	my $result = `aws ec2 describe-availability-zones --region $region`;
	my @zones = ();
	$result =~ s/[\r\n]//g;

	while($result =~ /\"State\": \"available\".*?\"ZoneName\": \"(.*?)\"/g) {
		push @zones, $1;
	}

	Log("... active zones = (" . join(',', @zones) . ")\n");
	return @zones;
} # GetActiveAvailabilityZones

sub GetEnvironmentStatus {
	my $environmentName = shift;
	Log("getting environment $environmentName health...\n");
	my $result = `aws elasticbeanstalk describe-environments --environment-name $environmentName --no-include-deleted`;
	$result =~ /.*?\"Status\"\: \"(.*?)\"/g;
	return $1;
} # GetEnvironmentStatus

sub GetLoadBalancerForEnvironment {
	my $environmentName = shift;
	Log("getting load-balancer for environment $environmentName...\n");
	my $result = `aws elasticbeanstalk describe-environment-resources --environment-name $environmentName`;
	$result =~ s/[\r\n]//g;
	$result =~ /.*?\"LoadBalancers\"\:.*?\"Name\"\: \"(awseb.*?)\"/g;
	return $1;
} # GetLoadBalancerForEnvironment

sub GetLoadBalancerDNSName {
	my $loadBalancerName = shift;
	Log("getting load balancer DNS Name for $loadBalancerName...\n");
	my $result = `aws elb describe-load-balancers --load-balancer-name $loadBalancerName`;
	$result =~ /.*?\"DNSName\"\: \"(.*?)\"/g;
	return $1;
} # GetLoadBalancerDNSName

sub GetLoadBalancerCanonicalZoneID {
	my $loadBalancerName = shift;
	Log("getting load balancer canonical zone ID for $loadBalancerName...\n");
	my $result = `aws elb describe-load-balancers --load-balancer-name $loadBalancerName`;
	$result =~ /.*?\"CanonicalHostedZoneNameID\"\: \"(.*?)\"/g;
	return $1;
} # GetLoadBalancerCanonicalZoneID

sub GetLoadBalancerCanonicalZoneIDFromEnvironment {
	my $applicationEnvironment = shift;
	my $loadBalancerName = GetLoadBalancerForEnvironment($applicationEnvironment);
	my $zoneId = GetLoadBalancerCanonicalZoneID($loadBalancerName);
	return $zoneId;
} # GetLoadBalancerCanonicalZoneIDFromEnvironment

sub GetHostedZoneID {
	my $domain = shift;
	Log("getting hosted zone ID for $domain...\n");
	my $result = `aws route53 list-hosted-zones-by-name --dns-name $domain --max-items 1`;
	$result =~ /.*?\"Id\"\: \"\/hostedzone\/(.*?)\"/g;
	return $1;
} # GetHostedZoneID

sub GetARNForRoleByName {
	my $name = shift;
	Log("getting ARN for IAM role $name...\n");
	my $result = `aws iam list-roles`;
	$result =~ /.*?\"Arn\"\: \"(.*?role\/$name)\"/g;
	return $1;
} # GetARNForRoleByName

sub GetARNForInstanceProfileByName {
	my $name = shift;
	Log("getting ARN for IAM instance profile $name...\n");
	my $result = `aws iam list-instance-profiles`;
	$result =~ /.*?\"Arn\"\: \"(.*?instance-profile\/$name)\"/g;
	return $1;
} # GetARNForInstanceProfileByName

sub AssignSecurityGroups {
	my $instanceId = shift;
	my $groupsRef = shift;

	Log("assigning security groups...\n");
	my $line = "aws ec2 modify-instance-attribute --groups " . join(' ', @$groupsRef) . "  --instance-id $instanceId";


} # AssignSecurityGroups

sub DeregisterAllHostServicesFromLoadBalancer {
	my $serviceConfiguration = shift;
	my $instanceId = shift;
	my $region = shift;

	Log("Deregistering $instanceId from all services...\n");


} # DeregisterAllHostServicesFromLoadBalancer

sub FetchAssetsFromS3 {
	my $assetsRef = shift;
	my $bucketName = shift;
	Log("Fetching assets from S3... (" . join(', ', @$assetsRef) . ")\n");
	foreach my $asset (@$assetsRef) {
		system("aws s3 cp s3://$bucketName/$asset $asset");
	}
} # FetchAssetsFromS3

sub FetchAssetFromS3 {
	my $s3 = shift;
	my $targetFilename = shift;
	Log("Copying asset from $s3 to $targetFilename\n");
	system("aws s3 cp $s3 $targetFilename");
} # FetchAssetFromS3

sub GetClusterConfiguration {
	my $configurationFile = shift;

	Log("Reading Cluster configuration from $configurationFile...\n");

	open(INPUT, "< $configurationFile") or die("couldn't open $configurationFile: $!");
	my $input = do { local $/; <INPUT> };
	close INPUT;

	my $clusterConfiguration = {};

	while($input =~ /.*?\"(.*?)\"\:\s+(.*?)[,\r\n]/g) {
		my $key = $1;
		my $value = $2;

		$value =~ s/\"//g;

		$clusterConfiguration->{$key} = $value;
	}

	return $clusterConfiguration;
} # GetClusterConfiguration

sub CurrentlyRegisteredWithLoadBalancer {
	my $elbName = shift;
	my $instanceId = shift;
	my $region = shift;

	my $result = `aws elb describe-load-balancers --load-balancer-name $elbName --region $region | grep $instanceId`;

	if($result =~ /$instanceId/) {
		Log("... we are currently registered with the load balancer\n");
		return 1;
	}
	Log("... we are not currently registered with the load balancer\n");
	return 0;
} # CurrentlyRegisteredWithLoadBalancer

sub DeregisterFromLoadBalancer {
	my $elbName = shift;
	my $instanceId = shift;
	my $region = shift;

	Log("ensuring de-registered from load balancer\n");
	if(CurrentlyRegisteredWithLoadBalancer($elbName, $instanceId, $region)) {
		Log("... de-registering from load balancer...\n");

		my $line = `aws elb deregister-instances-from-load-balancer --load-balancer-name $elbName --instances $instanceId --region $region`;
	}
} # DeregisterFromLoadBalancer

sub RegisterWithLoadBalancer {
	my $elbName = shift;
	my $instanceId = shift;
	my $region = shift;

	Log("ensuring registered with load balancer\n");
	if(!CurrentlyRegisteredWithLoadBalancer($elbName, $instanceId, $region)) {
		Log("... registering with load balancer...\n");

		my $line = `aws elb register-instances-with-load-balancer --load-balancer-name $elbName --instances $instanceId --region $region`;
	}
} # RegisterWithLoadBalancer

sub GetServiceConfiguration {
	my $configurationFile = shift;

	Log("Reading Service configuration from $configurationFile...\n");

	open(INPUT, "< $configurationFile") or die("couldn't open $configurationFile: $!");
	my $input = do { local $/; <INPUT> };
	close INPUT;

	$input =~ s/[\r\n]//g;

	my $serviceConfiguration = {};

	while($input =~ /.*?\{(.*?)\}/g) {
		my $thisServiceSource = $1;
		if($thisServiceSource =~ /.*?\"Name\"\:\s+\"(.*?)\"/g)
		{
			my $thisServiceName = $1;
			$serviceConfiguration->{$thisServiceName} = {};
			while($thisServiceSource =~ /.*?\"(.*?)\"\:\s+(.*?)[,\r\n]/g) {
				my $key = $1;
				my $value = $2;

				$value =~ s/\"//g;

				if($key ne "Name") {
					$serviceConfiguration->{$thisServiceName}->{$key} = $value;
				}
			}
		}
	}

	return $serviceConfiguration;
} # GetServiceConfiguration

sub UrlEncode {
	my $url = shift;
	$url =~ s/\//\%2F/g;
	$url =~ s/\:/\%3A/g;
	return $url;
} # UrlEncode

sub Run {
	my $line = shift;
	print $line . "\n";
	system($line);
} # Run

####################### Container functions #######################
sub IsContainerInState {
	my $imageName = shift;
	my $state = shift;
	my $ps = `docker ps --filter=status=$state | grep $imageName`;

	return 0 if($ps !~ /$imageName/);
	return 1;
} # IsContainerInState

sub IsContainerRunning {
	my $imageName = shift;
	return IsContainerInState($imageName, "running");
} # IsContainerRunning

sub IsContainerDead {
	my $imageName = shift;
	return IsContainerInState($imageName, "exited");
} # IsContainerDead

sub EnsureContainerDead {
	my $name = shift;
	Log("... ensuring that container $name is dead\n");
	if(IsContainerDead($name))
	{
		system("docker rm $name");
	}
} # EnsureContainerDead

sub GetContainerIP {
	my $containerId = shift;

	my $inspect = `docker inspect $containerId | grep IPAddress`;

	$inspect =~ /.*?\"IPAddress\"\: \"(.*?)\"\,/g;

	my $ip = $1;

	Log("... found container ip: $ip\n");

	return $ip;
} # GetContainerIP

1;
