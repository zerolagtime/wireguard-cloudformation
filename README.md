Launch EC2 Instance with Wireguard
==================================

This [Cloudformation](https://aws.amazon.com/cloudformation/) creates a personal [Wireguard](https://www.wireguard.com/) VPN server in AWS. I assume a cursory understanding of AWS console and Cloudformation. This deployment should fit completely within the free tier of AWS. If there are overruns, they should be under $5USD/mo, but probably only because additional resources were added to the account.

Precursor setup:
1. Set up an AWS account and either configure Identity Center for SSO login
   (preferred) or set up access keys.
2. Be on a Linux or MacOS system. You do not need root.
3. Open a terminal window
4. Ensure that the AWS command line interface (CLI) v2 is installed.
   A sysadmin may need to install this.
5. Set up access to the AWS account (e.g. `aws configure sso` or `aws configure`)
6. Login if you were already configure (`aws sso login`) and are using SSO
7. This repo is checked out to a folder (`git clone`)

Permission to perform the actions in the Stack, via the AdministratorAccess
built-in policy.

Steps:

1. Download the [Wireguard client](https://www.wireguard.com/install/) for 
   your platform that needs outgoing Internet protected
2. Log into AWS console and go to the region of preference. Set the
   environment variable "AWS_REGION" if you want to override the default.
3. Start it up: `./up.sh`
4. If the startup succeeds, the key for the client is under `keys/`
5. Transfer the key to the system that needs a tunnel and add the
   the key
6. If additional outside ports need added for listening service, like
   a P2P tool, use the AWS console to add Ingress rules.
   1. Go to _EC2_ in the console
   2. Go to _Security Groups_ on the left under _Network & Security_
   3. Click on the _Security group ID_ of the entry with `wg1-` in the
      _Security group name_ column
   4. Select the _Edit inbound rules_
   5. Do not delete the entry with port `51820`
   6. _Add rule_ for each protocol and port range to add
   7. Click _Save rules_
   8. If the Cloudformation Stack is run again, these rules will get removed.
7. If you want to make the ports always available, update the `wireguard-no-eip.json`
   file and edit the definition of `VpnSecurityGroup` (you will see a reference to
   the Wireguard UDP port 51820). Follow the JSON pattern for your protocol and port.
8. Tear down the VPN tunnel with `./down.sh`. This also invalidates the key
   on any clients. Delete keys server and client side when not in use as
   they can be used to decrypt recorded streams.

Of Note:

* The default AMI is Amazon Linux 2023. Periodically rebuild the stacks to 
  get updates, force key rotation, and to get a new public IP address
* EC2 disks and Logs are all encrypted
* This leverages Cloudflare's DNS 1.1.1.1
* Only IPv4 is supported at this time
* Boot logs and system logs to go Cloudwatch Log Groups and are 
  retained for 3 dayswill go to syslog but are only retained for three days
* Cloudwatch Metrics has bandwidth usage and up/down statistics to allow historical review
* A keypair is assigned to the instance if you have used a default key file
  with ssh-keygen, but security groups disable access by default
* Tearing down the stacks deletes the Cloudwatch logs, but not the metrics
  which have to expire according to the metrics timeline, a few days
* To add support for SSH or other ports on ingress, manually create them
  in the account and attach them to the instance after it is running

Debugging:
* If the stack fails to come up, look at the Cloudformation Stack `wg1`
  under _Events - updated_. This will narrow down which resource failed
  along with the most explanation you're probably going to get.
* After 5 minutes, see if Cloudwatch has logs you can use. If there are 
  logs, that means a lot of things went well and it's probably 
  something related to inherited AWS permissions.
* On the EC2 page for the instance, if it has been up a few minutes,
  the view logs with _Actions_, _Monitor and troubleshoot_, followed by
  _Get system log_. If the kernel release number is on the last line, 
  it's probably fine.

