#!/usr/bin/perl -w

use Common;

Log("Setting up Warden...\n");

my $serviceConfigurationFile = "service-configuration.txt";
my $clusterConfigurationFile = "cluster-configuration.txt";

my $instanceId = GetInstanceId();
my $region = GetRegion();
my $serviceConfiguration = GetServiceConfiguration($serviceConfigurationFile);
my $clusterConfiguration = GetClusterConfiguration($clusterConfigurationFile);

if(IsRedisStarted()) {
  Log("... Redis already started\n");
} else {
	EnsureContainerDead("redis");
	Log("... starting Redis\n");
	StartRedis();
}

if(IsRedxStarted()) {
	Log("... Redx already started\n");
} else {
	Log("... starting Redx\n");
	EnsureContainerDead("redx");
	my $redisAddress = GetRedisAddress();
	StartRedx($redisAddress, $serviceConfiguration);
}

if(IsAgentStarted()) {
	Log("... ECS Agent already started\n");
} else {
	EnsureContainerDead("ecs-agent");
	Log("... starting ECS agent\n");
	StartECSAgent($clusterConfiguration->{"Name"});
}

DeregisterAllHostServicesFromLoadBalancer($serviceConfiguration, $instanceId, $region);

RunServiceRegistrar();

RunServiceManager();

exit;

sub StopDockerService {
	Log("... Stopping Docker service\n");
	system("sudo service docker stop");
} # StopDockerService

sub StartDockerService {
	Log("... Starting Docker service\n");
	system("sudo service docker start");
} # StartDockerService

sub RunServiceRegistrar {
	Log("Running service registrar in detached screen...\n");
	system("screen -S service -d -m perl ./warden-registrar.pl");
} # RunServiceRegistrar

sub RunServiceManager {
	Log("Running service manager in detached screen...\n");
	system("screen -S service -d -m perl ./warden-manager.pl");
} # RunServiceManager

sub StartECSAgent {
	my $clusterName = shift;
	Log("Starting ECS Agent container...\n");
	system("docker run --name ecs-agent --detach=true --volume=/var/run/docker.sock:/var/run/docker.sock --volume=/var/log/ecs/:/log --publish=127.0.0.1:51678:51678 " .
		"--volume=/var/lib/ecs/data:/data --env=ECS_LOGFILE=/log/ecs-agent.log --env=ECS_LOGLEVEL=info --env=ECS_DATADIR=/data " .
		"--env=ECS_CLUSTER=$clusterName amazon/amazon-ecs-agent:latest");
} # StartECSAgent

sub IsAgentStarted {
	Log("Checking if ECS Agent is started...\n");

	return IsContainerRunning("ecs-agent");
} # IsAgentStarted

sub IsRedisStarted {
	Log("Checking if Redis is started...\n");

	return IsContainerRunning("redis:latest");
} # IsRedisStarted

sub IsRedxStarted {
	Log("Checking if Redx is started...\n");
	return IsContainerRunning("redx");
} # IsRedxStarted

sub GetRedisAddress {
	Log("Getting Redis IP Address...\n");

	$redisInspect = `docker inspect redis`;

	$redisInspect =~ /.*?\"IPAddress\"\: \"(.*?)\"\,/g;

	my $redisAddress = $1;

	Log("... Redis container IP Address = $redisAddress\n");

	return $redisAddress;
} # GetRedisAddress

sub StartRedx {
	my $redisAddress = shift;
	my $serviceConfiguration = shift;

	Log("Starting Redx container...\n");

	my @ports = (80, 8081, 8082);

	foreach my $serviceKey (keys %$serviceConfiguration) {
		my $service = $serviceConfiguration->{$serviceKey};
		push(@ports, $service->{"Port"});
	}

	my $portDefinitions = "";
	foreach my $port (@ports) {
		$portDefinitions .= "-p $port:$port ";
	}

	system("docker run -d --name redx $portDefinitions -e REDIS_HOST=\"\'$redisAddress\'\" -e PLUGINS=\\{\\'random\\'\\} cbarraford/redx");
} # StartRedx

sub StartRedis {
	Log("Starting Redis container...\n");
	system("docker run -d --name redis redis");
} # StartRedis
