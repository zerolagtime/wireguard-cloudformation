#!/bin/bash
# Copyright 2024 zerolagtime[at]gmail[dot]com
# See the LICENSE.txt for additional rights
#
# Stand up a small AWS EC2 instance that runs WireGuard,
# and then places the client configuration file in 
# the local folder for use by a desktop. Effectively,
# all traffic for a node is routed through AWS.

here=$(dirname "$0")
if [[ $here == "." ]]; then
   here=${PWD}
fi
function is_valid_json() {
   input_file=${1}
   if output=$(jq . ${input_file}); then
      /bin/true
   else
      echo "ERROR: $input_file is invalid json.  Stopping."
      echo "$output"
      exit 1
   fi
}

function is_deployed() {
   stack=$1
   output=$(aws cloudformation describe-stacks | jq --arg stack $stack -r '.Stacks[] | select(.StackName==$stack)')
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
   until [ "$status" == "${verb}_COMPLETE" -o "$status" == "FAILURE" -o "$status" == "ROLLBACK_COMPLETE" ]; 
   do
     status=$(aws cloudformation describe-stacks --stack-name $stack | jq --arg stack $stack -r '.Stacks[] | select(.StackName==$stack) | .StackStatus')
     if [ -z "$status" ]; then
        status="MISSING"
     fi
     if [ "$status" != "${verb}_COMPLETE" -a "$status" != "ROLLBACK_COMPLETE" ]; then 
        echo "[$(date)] [INFO] [$stack] waiting for stack to come up.  Currently $status"
        sleep 5
     fi
   done
   if [ "$status" != "${verb}_COMPLETE" ]; then
     echo "[$(date)] [WARN] [$stack] $verb operation failed.  Currently $status"
     return 1
   fi
   echo "[$(date)] [INFO] [$stack] stack is not up.  Currently $status"
   return 0
}
function die() {
   msg="$*"
   echo "[$(date)] [FATAL] $msg" 1>&2 
   exit 1
}
EIP_TEMPLATE="$here/wireguard-eip.json"
EIP_STACK=wg1-eip
EC2_TEMPLATE="$here/wireguard-no-eip.json"
EC2_STACK=wg1
is_valid_json "$EIP_TEMPLATE"
is_valid_json "$EC2_TEMPLATE"
output=$(is_deployed $EIP_STACK)
if [ $? -eq 1 ]; then
   aws cloudformation create-stack --stack-name $EIP_STACK \
       --template-body file://${EIP_TEMPLATE} || \
       die "stack w$EIP_STACK could not deploy"
   if ! wait_for_stack $EIP_STACK; then
      die "Stack $EIP_STACK failed to deploy"
   fi
else
   aws cloudformation update-stack --stack-name $EIP_STACK \
       --template-body file://${EIP_TEMPLATE}  
   err=$?
   if [ $err -eq 0 ]; then
      if ! wait_for_stack $EIP_STACK UPDATE; then
         die "Stack $EIP_STACK failed to update"
      fi
   elif [ $err -eq 255 ]; then
      echo "[$(date)] [INFO] [$EIP_STACK] No updates needed to stack" 1>&2 
   else
      die "stack $EIP_STACK never finished updating"
   fi
fi
get_config=0
default_sg=$(aws ec2 describe-security-groups | jq -r '.SecurityGroups[] | select(.GroupName=="default") | .GroupId ' | head -1)
if is_deployed $EC2_STACK ; then
   aws cloudformation update-stack --stack-name $EC2_STACK \
         --template-body file://${EC2_TEMPLATE} \
         --parameters ParameterKey=VpnSecurityGroupID,ParameterValue=$default_sg \
         --capabilities CAPABILITY_IAM
   err=$?
   if [ $err -eq 0 ]; then
      if ! wait_for_stack $EC2_STACK UPDATE; then
         die "Stack $EC2_STACK failed to update"
      fi
   elif [ $err -eq 255 ]; then
      echo "[$(date)] [INFO] [$EC2_STACK] No updates needed to $EC2_STACK stack" 1>&2 
   else
      die "stack $EC2_STACK never finished updating"
   fi
   if ! wait_for_stack $EC2_STACK UPDATE; then 
      die "Stack $EC2_STACK failed to update"
   fi
else
   aws cloudformation create-stack --stack-name $EC2_STACK \
       --template-body file://${EC2_TEMPLATE} \
       --parameters ParameterKey=VpnSecurityGroupID,ParameterValue=$default_sg \
       --capabilities CAPABILITY_IAM
   if ! wait_for_stack $EC2_STACK; then
      $here/down.sh; 
      die "Stack $EC2_STACK did not come up"
      get_config=0
   else
      get_config=1
   fi
fi
if [ $get_config -eq 1 ]; then
   # allow for up.sh to be called in a folder away from where the key is stored
   conf=${PWD}/keys/aws_$(date +%Y%m%d).conf
   triesLeft=25
   delays=15
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
   mv $conf{,.failed}
   echo "[$(date)] [INFO] Wireguard config not updated.  Use last known configuration file."
fi
