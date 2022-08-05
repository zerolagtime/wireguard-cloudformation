#!/bin/bash

function is_deployed() {
   stack=$1
   output=$(aws cloudformation describe-stacks | jq --arg stack $stack -r '.Stacks[] | select(.StackName==$stack)| .StackName')
   if [ -n "$output" ]; then
      return 0; #true
   else
      return 1; #false
   fi
}
function wait_for_stack() {
   stack=$1
   verb=${2:-CREATE}
   status="PENDING"
   until [ "$status" == "${verb}_COMPLETE" -o "$status" == "FAILURE" ]; 
   do
     status=$(aws cloudformation describe-stacks --stack-name $stack | jq -r '.Stacks[].StackStatus')
     if [ "$status" != "${verb}_COMPLETE" ]; then 
        echo "[$(date)] [INFO] [$stack] waiting for stack to come up.  Currently $status"
        sleep 5
     fi
   done
   if [ "$status" != "${verb}_COMPLETE" ]; then
     echo "[$(date)] [WARN] [$stack] $verb operation failed.  Currently $status"
     return 1
   fi
   echo "[$(date)] [INFO] [$stack] stack is up.  Currently $status"
   return 0
}
function die() {
   msg="$*"
   echo "[$(date)] [FATAL] $msg" 1>&2 
   exit 1
}
output=$(is_deployed wg1-eip)
if [ $? -eq 1 ]; then
   aws cloudformation create-stack --stack-name wg1-eip --template-body file://wireguard-eip-master.json || die "stack wg1-eip could not deploy"
   wait_for_stack wg1-eip  || die "Stack wg1-eip failed to deploy"
else
   aws cloudformation update-stack --stack-name wg1-eip --template-body file://wireguard-eip-master.json 
   err=$?
   if [ $err -eq 0 ]; then
      wait_for_stack wg1-eip UPDATE || die "Stack wg1-eip failed to update"
   elif [ $err -eq 255 ]; then
      echo "[$(date)] [INFO] [wg-eip1] No updates needed to stack" 1>&2 
   else
      die "stack wg1-eip never finished updating"
   fi
fi
get_config=0
output=$(is_deployed wg1)
if [ $? -eq 1 ]; then
   aws cloudformation create-stack --stack-name wg1 --template-body file://wireguard-master.json --parameters ParameterKey=VpnSecurityGroupID,ParameterValue=sg-0c35a32f2d961d3e5 --capabilities CAPABILITY_IAM
   wait_for_stack wg1 || (./down.sh; die "Stack wg1 did not come up")
   get_config=1
else
   aws cloudformation update-stack --stack-name wg1 --template-body file://wireguard-master.json --parameters ParameterKey=VpnSecurityGroupID,ParameterValue=sg-0c35a32f2d961d3e5 --capabilities CAPABILITY_IAM
   err=$?
   if [ $err -eq 0 ]; then
      wait_for_stack wg1 UPDATE || (die "Stack wg1 failed to update")
   elif [ $err -eq 255 ]; then
      echo "[$(date)] [INFO] [wg1] No updates needed to wg1 stack" 1>&2 
   else
      die "stack wg1 never finished updating"
   fi
   wait_for_stack wg1 UPDATE || die "Stack wg1 failed to update"
fi
if [ $get_config -eq 1 ]; then
   conf=aws_$(date +%Y%m%d).conf
   triesLeft=10
   delays=10
   while [ $triesLeft -gt 0 ]; do
      printf "Waiting for secure configuration to post. Tries left: %2d                  " $triesLeft
      aws ssm get-parameter --name "ClientConfig" --with-decryption | jq -r '.Parameter.Value' > $conf  2>/dev/null
      if [ -s $conf ]; then
         echo Success
         break
      else
         printf "Still waiting\r"
         sleep $delays
         triesLeft=$[ $triesLeft - 1 ]
      fi
   done
   echo "[$(date)] [INFO] Wireguard config is in $conf"
   if [ -s $conf ]; then
      echo "[$(date)] [INFO] Deleting config parameter from AWS"
      aws ssm delete-parameter --name "ClientConfig"
   else
      echo "[$(date)] [WARN] Config parameter not downloaded and so not deleted."
   fi
else
   echo "[$(date)] [INFO] Wireguard config not updated.  Use last known configuration file."
fi
