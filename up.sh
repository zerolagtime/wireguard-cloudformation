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
        printf "[$(date)] [INFO] %s\n" \
         "[$stack] waiting for stack to come up.  Currently $status"
        sleep 5
     fi
   done
   if [ "$status" != "${verb}_COMPLETE" ]; then
     echo
     printf "[$(date)] [WARN] %s\n" \
      "[$stack] $verb operation failed.  Currently $status"
     return 1
   fi
   echo
   printf "[$(date)] [INFO] %s\n" \
      "[$stack] stack is up.  Currently $status"
   return 0
}
function die() {
   msg="$*"
   echo "[$(date)] [FATAL] $msg" 1>&2 
   exit 1
}
function get_ssh_public_key() {
   if [ -d "$HOME/.ssh" ]; then
      # Define the default public key filenames in order of security (most secure first)
      key_files=("id_ed25519.pub" "id_ecdsa.pub" "id_rsa.pub" "id_dsa.pub")

      # Iterate over the key files
      for key_file in "${key_files[@]}"; do
         key_path="$HOME/.ssh/$key_file"
         if [[ -f "$key_path" ]]; then
            echo "$key_path"
            return 0
         fi
      done
   fi
   echo "[$(date)] [WARN] No default public keys in ~/.ssh. Remote SSH not available." 1>&2
   return 1
}

function get_stack_deploy_errors() {
   stack="$1"
   aws cloudformation describe-stack-events --stack-name ${stack} \
     --query "StackEvents[?ResourceStatus=='CREATE_FAILED'] | sort_by(@, &Timestamp)[0].[LogicalResourceId, ResourceStatusReason]" \
     --output yaml | awk 'NR > 1 {print "   " $0} NR==1 {print}'
}

EIP_TEMPLATE="$here/wireguard-eip.json"
EIP_STACK=wg1-eip
EC2_TEMPLATE="$here/wireguard-no-eip.json"
EC2_STACK=wg1
pub_key_file=$(get_ssh_public_key)
if [[ -n $pub_key_file ]]; then
   pub_key_value="\"$(<"$pub_key_file")\""
   pub_key_param="ParameterKey=PublicKey,ParameterValue=$pub_key_value"
fi

is_valid_json "$EIP_TEMPLATE"
is_valid_json "$EC2_TEMPLATE"
output=$(is_deployed $EIP_STACK)
if [ $? -eq 1 ]; then
   if ! aws cloudformation create-stack --stack-name $EIP_STACK \
       --template-body file://${EIP_TEMPLATE} --no-cli-pager; then
      die "stack $EIP_STACK could not deploy"
   fi
   if ! wait_for_stack $EIP_STACK; then
      die "Stack $EIP_STACK failed to deploy"
   fi
else
   output=$(aws cloudformation update-stack --stack-name $EIP_STACK \
       --template-body file://${EIP_TEMPLATE} --no-cli-pager 2>&1 )
   err=$?
   echo "[$(date)] DEBUG: \"aws cloudformation update-stack --stack-name $EIP_STACK\" exited with code $err"
   if [ $err -eq 0 ]; then
      if ! wait_for_stack $EIP_STACK UPDATE; then
         die "Stack $EIP_STACK failed to update\n$output"
      fi
   elif [ $err -eq 254 ]; then
      echo "[$(date)] [INFO] [$EIP_STACK] No updates needed to stack" 1>&2 
   else
      die "stack $EIP_STACK never finished updating"
   fi
fi
get_config=0
default_sg=$(aws ec2 describe-security-groups | jq -r '.SecurityGroups[] | select(.GroupName=="default") | .GroupId ' | head -1)
if is_deployed $EC2_STACK ; then
   output=$(aws cloudformation update-stack --stack-name $EC2_STACK \
         --template-body file://${EC2_TEMPLATE} \
         --parameters "$pub_key_param" ParameterKey=VpnSecurityGroupID,ParameterValue=$default_sg \
         --capabilities CAPABILITY_IAM \
         --no-cli-pager 2>&1)
   err=$?
   if [ $err -eq 0 ]; then
      if ! wait_for_stack $EC2_STACK UPDATE; then
         die "Stack $EC2_STACK failed to update\n$output"
      fi
   elif [ $err -eq 254 ]; then
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
       --parameters "$pub_key_param" ParameterKey=VpnSecurityGroupID,ParameterValue=$default_sg \
       --capabilities CAPABILITY_IAM \
       --no-cli-pager
   if ! wait_for_stack $EC2_STACK; then
      get_stack_deploy_errors $EC2_STACK
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
      printf "%s Waiting for secure configuration to post. Tries left: %2d " \
         "[$(date)] [INFO]" $triesLeft
      aws ssm get-parameter --name "ClientConfig" --with-decryption 2>/dev/null | jq -r '.Parameter.Value' > $conf  
      if [ -s $conf ]; then
         echo "Success         "
         break
      else
         printf "Still waiting  \r"
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
   if [[ -f $conf ]]; then
      mv $conf{,.failed}
      echo "[$(date)] [INFO] Wireguard config not updated.  Use last known configuration file."
   fi
fi
