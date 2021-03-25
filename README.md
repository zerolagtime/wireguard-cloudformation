Launch EC2 Instance with Wireguard
==================================

This [Cloudformation](https://aws.amazon.com/cloudformation/) creates a personal [Wireguard](https://www.wireguard.com/) VPN server in AWS. I assume a cursory understanding of AWS console and Cloudformation.

You will need the following:

* In the AWS console, launch the `wireguard-eip-master.json` template first. It will export the elastic IP used by the `wireguard-master.json`template (so you can conveniently use the same public IP).  The true/false option allows one to stand up the `wireguard-master.json` with out the export from the EIP, if undesired.
* Your VPC's default security group ID (auto-populated in Cloudformation dropdown)

Of Note:

* The default AMI is Amazon Linux 2 and it grabs the latest (NOT FOR PRODUCTION)
* This leverages Cloudflare's DNS 1.1.1.1
* The client config is sent to a kms encrypted SSM Parameter Store
* There is a force reboot at the end of userdata so that wireguard comes up gracefully
* The instance does not get an ssh key passed in and ssh port is not open

Steps:

* Log into AWS console and go to the region of preference
* Depoly the `wireguard-eip-master.json` template (button here?)
* Deploy the the `wireguard-master.json` template (button here?)
* After the Cloudformation is deployed and server has rebooted click the link in the Cloudformation Outputs to see the encrypted client config in SSM Parameter Store
* Paste config into your client and activate

Todo:

* Generate QR code for mobile clients
