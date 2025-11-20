#!/bin/env python3
import re
import subprocess

import boto3
import requests

# Define the CloudWatch namespace
CLOUDWATCH_NAMESPACE = 'WireGuard'

def get_instance_region():
    """Retrieve the instance region using IMDSv2."""
    token_url = "http://169.254.169.254/latest/api/token"
    metadata_url = "http://169.254.169.254/latest/meta-data/placement/region"

    # Step 1: Retrieve the token
    try:
        # Fetch the token
        token_response = requests.put(token_url, headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"})
        token_response.raise_for_status()  # Raise an error for bad responses
        token = token_response.text
    except requests.RequestException as e:
        print(f"Error retrieving token for IMDS: {e}")
        return None

    # Step 2: Use the token to access the metadata
    try:
        response = requests.get(metadata_url, headers={"X-aws-ec2-metadata-token": token})
        response.raise_for_status()  # Raise an error for bad responses
        region = response.text
        return region
    except requests.RequestException as e:
        print(f"Error retrieving instance region: {e}")
        return None

def clean_peer_id(peer_id):
    return peer_id
    # Replace any non-alphanumeric character with 'Z' and make uppercase
    #return re.sub(r'[^a-zA-Z0-9]', 'Z', peer_id).upper()

def get_wireguard_metrics():
    result = subprocess.run(['wg', 'show', 'all', 'dump'], stdout=subprocess.PIPE, text=True)
    metrics = []

    for rownum, line in enumerate(result.stdout.strip().split('\n')):
        columns = line.split('\t')
        # Skip the first line and adjust the columns as per your requirements
        if len(columns) >= 5 and rownum > 0:
            # Subsequent  lines are printed for each peer and contain
            #  in order separated by tab: interface[0],
            #  public-key[1], preshared-key[2], endpoint[3],
            #  allowed-ips[4], latest-handshake[5], 
            #  transfer-rx[6], transfer-tx[7], persistent-keepalive[7]
            print(f'Input_wg_dump_row={",".join(columns)}')
            del columns[3]  # deletes allowed-ips
            del columns[2]  # deletes endpoint
            del columns[1]  # deletes preshared-key

            print(f'Modified_wg_dump_row={",".join(columns)}')
            print(f'Columns: peer_id, last_handshake, received_bytes, transmitted_bytes')
            # Cleaned peer ID
            peer_id = clean_peer_id(columns[0])[:16]
            last_handshake, received_bytes, transmitted_bytes = columns[1:4]
            
            # Create metric data to send
            metrics.append({
                'MetricName': 'LastHandshake',
                'Value': float(last_handshake) if last_handshake.isdigit() else 0,  
                'Unit': 'Seconds',
                'Dimensions': [{'Name': 'ClientID', 'Value': peer_id}]
            })
            metrics.append({
                'MetricName': 'ReceivedBytes',
                'Value': float(received_bytes) if received_bytes.isdigit() else 0,
                'Unit': 'Bytes',
                'Dimensions': [{'Name': 'ClientID', 'Value': peer_id}]
            })
            metrics.append({
                'MetricName': 'TransmittedBytes',
                'Value': float(transmitted_bytes) if transmitted_bytes.isdigit() else 0,
                'Unit': 'Bytes',
                'Dimensions': [{'Name': 'ClientID', 'Value': peer_id}]
            })

    return metrics

def send_metrics_to_cloudwatch(metrics, region):
    # Create the CloudWatch client with the specified region
    cloudwatch = boto3.client('cloudwatch', region_name=region)

    # Batch metrics in groups of 20 (max allowed per PutMetricData call)
    for i in range(0, len(metrics), 20):
        print('Writing metrics to Cloudwatch Metrics')
        cloudwatch.put_metric_data(
            Namespace=CLOUDWATCH_NAMESPACE,
            MetricData=metrics[i:i+20]  # Send a chunk of up to 20 metrics
        )

if __name__ == "__main__":
    region = get_instance_region()
    if region:  # Proceed only if region is successfully obtained
        metrics = get_wireguard_metrics()
        send_metrics_to_cloudwatch(metrics, region)
    else:
        print("Failed to retrieve the instance region, exiting.")
