#!/usr/bin/perl -w

use Common;

my $serviceConfigurationFile = "service-configuration.txt";
my $SLEEP_TIME = 10;

my $instanceId = GetInstanceId();
my $region = GetRegion();

my $serviceConfiguration = GetServiceConfiguration($serviceConfigurationFile);

while(1) {
	foreach my $serviceName (keys %$serviceConfiguration) {
		my $service = $serviceConfiguration->{$serviceName};
		MaintainService($service, $instanceId, $region);
	}

	Log("sleeping for $SLEEP_TIME seconds...\n");
	sleep($SLEEP_TIME);
}

exit;


sub MaintainService {
	my $service = shift;
	my $instanceId = shift;
	my $region = shift;

	my $imageName = $service->{ContainerName};
	my $elbUrl = $service->{LoadBalancerUrl};
	my $elbName = $service->{LoadBalancerName};
	my $site = $service->{Site};
	my $targetBackend = $service->{BackendName};
	my $targetPort = $service->{Port};

	Log("image name:\t$imageName\n");
	Log("elb url:\t$elbUrl\n");
	Log("elb name:\t$elbName\n");
	Log("site:\t$site\n");
	Log("backend name:\t$targetBackend\n");
	Log("port:\t$targetPort\n");

	# get list of running containers matching 'image-server-node'
	my $containerEndpoints = GetContainerEndpoints($imageName);

	# ensure that the frontend is defined
	EnsureFrontend($elbUrl, $site, $targetBackend);

	# synchronise list of backend servers in redx
	SynchroniseBackends($elbName, $containerEndpoints, $targetBackend, $targetPort, $region);
}

sub GetContainerEndpoints {
	my $containerName = shift;

	Log("scanning containers matching $containerName\n");

	my @containerOutput = `docker ps -a --filter=status=running | grep $containerName`;

	my %containers;

	foreach my $containerOutputLine (@containerOutput) {
		$containerOutputLine =~ /^(.*?)\s.*$/;
		my $containerId = $1;
		Log("... inspecting $containerId\n");
		# 0.0.0.0:32768->8080/tcp
		$containerOutputLine =~ /.*?\s+\d+\.\d+\.\d+\.\d+\:(\d+)\-\>(\d+)\/tcp.*?/;
		my $containerPort = $1;
		my $containerIP = GetContainerIP($containerId);
		Log("... found $containerIP:$containerPort\n");
		$containers{$containerId} = $containerIP;
	}

	return \%containers;
} # GetContainerEndpoints

sub EnsureFrontend {
	my $elbUrl = shift;
	my $site = shift;
	my $targetBackend = shift;

	# make sure we have the mapping from 'frontend:$elbUrl/fcgi-bin' to 'docker'
	Log("ensuring frontend for $elbUrl$site -> $targetBackend is set in Redx\n");

	AddFrontend($elbUrl, $site, $targetBackend);
} # EnsureFrontend

sub AddFrontend {
	my $url = shift;
	my $site = shift;
	my $targetBackend = shift;

	my $siteEnc = UrlEncode($site);

	my $line = `curl -s -X POST localhost:8081/frontends/$url$siteEnc/$targetBackend`;
} # AddFrontend

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
	my $region = shift;

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
				my $containerEndpoint = $$containers{$containerId} . ":" . $targetPort;
				if($backendKey eq $containerEndpoint) {
					Log("... server $backendKey has a current container with id $containerId and endpoint $containerEndpoint\n");
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
			DeregisterFromLoadBalancer($elbName, $instanceId, $region);
		} else {
			Log("... no containers to synchronise but backends exist - ensuring registered on elb.\n");
			RegisterWithLoadBalancer($elbName, $instanceId, $region);
		}

		return;
	}

	my $addedServer = 0;

	foreach my $containerId (keys %$containers) {
		my $containerEndpoint = $$containers{$containerId} . ":" . $targetPort;
		my $backendFound = 0;

		foreach my $backendKey (@backendKeys) {
			if($backendKey eq $containerEndpoint) {
				$backendFound = 1;
				last;
			}
		}

		if($backendFound == 0) {
			# need backend for this container
			my $backendKey = UrlEncode($containerEndpoint);
			AddServer($backendName, $backendKey, $containerId, $containerEndpoint);
			$addedServer = 1;
		}
	}

	if($addedServer == 1) {
		Log("... at least one server was added so ensuring registered with load balancer\n");
		RegisterWithLoadBalancer($elbName, $instanceId, $region);
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
	my $containerEndpoint = shift;

	Log("... adding server $backendKey for container with id $containerId and endpoint $containerEndpoint\n");
	Run("curl -s -X POST localhost:8081/backends/$backendName/$backendKey");
} # AddServer
