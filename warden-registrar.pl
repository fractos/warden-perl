#!/usr/bin/perl -w

my $imageName = shift || "image-server-node";
my $elbUrl = shift || "image-server-layer.eu-west-1.dlcs";
my $elbName = shift || "image-server-layer";
my $site = shift || "/fcgi-bin";
my $targetBackend = shift || "docker";
my $targetPort = shift || "8080";

my $instanceId = GetInstanceId();

Log("image name:\t$imageName\n");

while(1) {
	# get list of running containers matching 'image-server-node'
	my $containers = GetContainers($imageName);

	
	# ensure that the frontend is defined
	EnsureFrontend($elbUrl, $site, $targetBackend);

	# synchronise list of backend servers in redx
	SynchroniseBackends($elbName, $containers, $targetBackend, $targetPort);

	Log("sleeping ...\n");
	sleep(10);
}

exit;

sub GetContainers {
	my $containerName = shift;

	Log("scanning containers matching $containerName\n");

	my @containerOutput = `docker ps -a --filter=status=running | grep $containerName`;

	my %containers;

	foreach my $containerOutputLine (@containerOutput) {
		$containerOutputLine =~ /^(.*?)\s.*$/;
		my $containerId = $1;
		Log("... inspecting $containerId\n");
		$containers{$containerId} = InspectContainer($containerId);
	}

	return \%containers;
} # GetContainers

sub InspectContainer {
	my $containerId = shift;

	my $inspect = `docker inspect $containerId | grep IPAddress`;

	$inspect =~ /.*?\"IPAddress\"\: \"(.*?)\"\,/g;

	my $ip = $1;

	Log("... found container ip: $ip\n");

	return $ip;
} # InspectContainer

sub EnsureFrontend {
	my $elbUrl = shift;
	my $site = shift;
	my $targetBackend = shift;

	# make sure we have the mapping from 'frontend:$elbUrl/fcgi-bin' to 'docker'
	Log("ensuring frontend for $elbUrl$site -> $targetBackend is set in Redx\n");

	my $result = `curl -s localhost:8081/frontends`;
	
	if($result =~ /\"data\"\:\{\}/) {
		Log("... setting frontend in Redx\n");
		AddFrontend($elbUrl, $site, $targetBackend);
		AddFrontend("localhost", $site, $targetBackend);
	}
} # EnsureFrontend

sub AddFrontend {
	my $url = shift;
	my $site = shift;
	my $targetBackend = shift;
	
	my $siteEnc = UrlEncode($site);
	
	my $line = `curl -s -X POST localhost:8081/frontends/$url$siteEnc/$targetBackend`;
} # AddFrontend

sub UrlEncode {
	my $url = shift;
	$url =~ s/\//\%2F/g;
	$url =~ s/\:/\%3A/g;
	return $url;
} # UrlEncode

sub ParseBackendString {
	my $backends = shift;
	$backends =~ s/.*?\"servers\"\:\[(.*?)\].*/$1/;
	$backends =~ s/\"//g;
	my @results = split(/,/, $backends);
	return @results;
} # ParseBackendString

sub SynchroniseBackends {
	my $elbName = shift;
	my $containers = shift;
	my $backendName = shift;
	my $targetPort = shift;

	Log("synchronising backends with redis\n");

	my $backends = `curl -s localhost:8081/backends/$backendName`;
	
	# {"message":"OK","data":{}}[
	# {"message":"OK","data":{"servers":["172.0.0.4:8080","172.0.0.5:8080"],"config":{}}}[

	Log("... removing any stale backend servers\n");

	my @backendKeys = ParseBackendString($backends);
	
	Log("... found these backends: " . join(',', @backendKeys) . "\n");
	
	my $backendsExist = 0;
	
	if($backends =~ /Entry does not exist/) {
		Log("... no backends found\n");
	} else {
		
		Log("... found " . scalar @backendKeys . " backend servers\n");
		
		foreach my $backendKey (@backendKeys) {
			my $containerFound = 0;
			foreach my $containerId (keys %$containers) {
				my $containerIp = $$containers{$containerId};
				if($backendKey eq "$containerIp:$targetPort") {
					Log("... server $backendKey has a current container with id $containerId and ip $containerIp\n");
					# remove this one as it is sorted
					delete $$containers{$containerId};
					$containerFound = 1;
					last;
				}
			}
			if($containerFound == 0) {
				RemoveServer($backendName, $backendKey);
			} else {
				$backendsExist = 1;
			}
		}
	}

	# now add any new containers to backend servers

	Log("... adding any new containers\n");
	
	if(scalar keys %$containers == 0) {
		Log("... nothing to synchronise\n");

		if($backendsExist == 0) {
			Log("... no containers to synchronise and no backends exist - ensuring de-registered from elb.\n");
			DeregisterFromLoadBalancer($elbName, $instanceId);		
		} else {
			Log("... no containers to synchronise but backends exist - ensuring registered on elb.\n");			
			RegisterWithLoadBalancer($elbName, $instanceId);
		}
		
		return;
	}
	
	my $addedServer = 0;
	
	foreach my $containerId (keys %$containers) {
		my $containerIp = $$containers{$containerId};
		my $backendFound = 0;
		
		foreach my $backendKey (@backendKeys) {
			if($backendKey =~ /^$containerIp\:$targetPort$/) {
				$backendFound = 1;
				last;
			}
		}
		
		if($backendFound == 0) {
			# need backend for this container
			my $backendKey = UrlEncode("$containerIp:$targetPort");
			AddServer($backendName, $backendKey, $containerId, $containerIp);
			$addedServer = 1;
		}
	}
	
	if($addedServer == 1) {
		Log("... at least one server was added so ensuring registered with load balancer\n");
		RegisterWithLoadBalancer($elbName, $instanceId);
	}
	
} # SynchroniseBackends

sub RemoveServer {
	my $backendName = shift;
	my $backendKey = shift;
	
	Log("... removing server $backendKey from config\n");
	Run("curl -s -X DELETE localhost:8081/backends/$backendName/$backendKey");	
} # RemoveServer

sub AddServer {
	my $backendName = shift;
	my $backendKey = shift;
	my $containerId = shift;
	my $containerIp = shift;
	
	Log("... adding server $backendKey for container with id $containerId and ip $containerIp\n");
	Run("curl -s -X POST localhost:8081/backends/$backendName/$backendKey");
} # AddServer

sub GetInstanceId {
	Log("getting instance id...\n");
	my $instanceId = `wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`;
	$instanceId =~ s/[\r\n]//g;
	Log("... instance id = $instanceId\n");
	return $instanceId;
} # GetInstanceId

sub DeregisterFromLoadBalancer {
	my $elbName = shift;
	my $instanceId = shift;

	Log("ensuring de-registered from load balancer\n");
	if(CurrentlyRegisteredWithLoadBalancer($elbName, $instanceId)) {
		Log("... de-registering from load balancer...\n");

		my $line = `aws elb deregister-instances-from-load-balancer --load-balancer-name $elbName --instances $instanceId --region eu-west-1`;
	}
} # DeregisterFromLoadBalancer

sub RegisterWithLoadBalancer {
	my $elbName = shift;
	my $instanceId = shift;

	Log("ensuring registered with load balancer\n");
	if(!CurrentlyRegisteredWithLoadBalancer($elbName, $instanceId)) {
		Log("... registering with load balancer...\n");
		
		my $line = `aws elb register-instances-with-load-balancer --load-balancer-name $elbName --instances $instanceId --region eu-west-1`;
	}
} # RegisterWithLoadBalancer

sub CurrentlyRegisteredWithLoadBalancer {
	my $elbName = shift;
	my $instanceId = shift;
	
	my $result = `aws elb describe-load-balancers --load-balancer-name $elbName | grep $instanceId`;
	
	if($result =~ /$instanceId/) {
		Log("... we are currently registred with the load balancer\n");
		return 1;
	}
	Log("... we are not currently registered with the load balancer\n");
	return 0;
} # CurrentlyRegisteredWithLoadBalancer

sub Log {
	my $message = shift;
	($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();

	printf("%d/%02d/%02d %02d:%02d:%02d %s", $year, $mon, $mday, $hour, $min, $sec, $message);
} # Log

sub Run {
	my $line = shift;
	print $line . "\n";
	system($line);
} # Run