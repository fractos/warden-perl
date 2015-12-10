#!/usr/bin/perl -w

my $instanceId = GetInstanceId();
my $bucketName = shift || "warden-bootstrap";

my @packages = ('docker', 'nfs-utils');

UpdateAndInstall(\@packages);

my @assets = (
	'warden-setup.pl',
	'warden-registrar.pl',
	'warden-manager.pl',
	'nfs-configuration.txt',
	'service-configuration.txt',
	'cluster-configuration.txt',
	'Common.pm',
	'redis-cli'
);

FetchAssetsFromS3(\@assets, $bucketName);

if(-f "nfs-configuration.txt") {
	my $nfsConfiguration = ReadNFSConfiguration("nfs-configuration.txt");

	if(scalar keys %$nfsConfiguration > 0) {
			foreach my $nfsKey (keys %$nfsConfiguration) {
				my $nasFolder = $nfsKey;
				my $nfsPath = $nfsConfiguration->{$nfsKey};
				CreateAndMountNFSFolder($nasFolder, $nfsPath);
			}
	}
}

UnSudoDocker();

StartDocker();

RunWardenSetup();

exit;

sub ReadNFSConfiguration {
	my $configurationFile = shift;

	Log("Reading NFS configuration...\n");
	my $nfsConfiguration = {};

	open(INPUT, "< $configurationFile") or die("couldn't open $configurationFile: $!");
	my @lines = <INPUT>;
	close INPUT;

	foreach my $line (@lines) {
		$line =~ s/[\r\n]//g;
		$line =~ /^(.*?)\s(.*)$/;
		$nfsConfiguration->{$1} = $2;
	}

	return $nfsConfiguration;
} # ReadNFSConfiguration

sub RunWardenSetup {
	Log("Calling Warden setup...\n");
	system("perl ./warden-setup.pl");
} # RunWardenSetup

sub StartDocker {
	Log("Starting docker service...\n");
	system("service docker start");
} # StartDocker

sub UnSudoDocker {
	Log("Un-sudo-ing Docker...\n");
	system("usermod -a -G docker ec2-user");
} # UnSudoDocker

sub CreateAndMountNFSFolder {
	my $nasFolder = shift;
	my $nfsPath = shift;

	Log("creating NFS folder...\n");
	system("mkdir -p $nasFolder");

	Log("mounting $nasFolder via NFS...\n");
	system("mount -t nfs $nfsPath $nasFolder");
} # CreateAndMountNFSFolder

sub UpdateAndInstall {
	my $packagesRef = shift;
	Log("updating yum packages...\n");
	system("yum update -q -y");

	Log("installing " . join(', ', @$packagesRef) . "...\n");

	my $packages = join(' ', @$packagesRef);
	system("yum install $packages -q -y");
} # UpdateAndInstall

sub FetchAssetsFromS3 {
	my $assetsRef = shift;
	my $bucketName = shift;
	Log("Fetching assets from S3... (" . join(', ', @$assetsRef) . ")\n");
	foreach my $asset (@$assetsRef) {
		system("aws s3 cp s3://$bucketName/$asset $asset");
	}
} # FetchAssetsFromS3

sub GetInstanceId {
	Log("getting instance id...\n");
	my $instanceId = `wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`;
	$instanceId =~ s/[\r\n]//g;
	Log("... instance id = $instanceId\n");
	return $instanceId;
} # GetInstanceId

sub Log {
	my $message = shift;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();

	printf("%d/%02d/%02d %02d:%02d:%02d %s", $year, $mon, $mday, $hour, $min, $sec, $message);
} # Log
