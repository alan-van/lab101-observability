#!/bin/bash

#Create VPC End point
VPC_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id $vpc_id \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.${REGION}.aps-workspaces \
  --subnet-ids $subnet_id1 $subnet_id2  \
  --no-private-dns-enabled \
  --query 'VpcEndpoint.VpcEndpointId' \
  --profile lqvan \
  --output text) 

echo "export VPC_PEERING_ID=${VPC_PEERING_ID}" >> delete.env


#Create Pvt Hosted Zone on Route53
HOSTED_ZONE=$(aws route53 create-hosted-zone \
    --name aps-workspaces.${REGION}.amazonaws.com \
    --caller-reference $(date +%F%T) \
    --vpc VPCRegion=$REGION,VPCId=$vpc_id \
    --hosted-zone-config Comment="VPCE Hosted Zone",PrivateZone=true \
    --profile lqvan \
    --query 'HostedZone.Id' | tr -d \")
echo "export HOSTED_ZONE=${HOSTED_ZONE}" >> delete.env


#Sleep 60 seconds to allow VPC end point createion
sleep 60


#Get DNS name associated with VPC Endpoint
DNS_NAME=$(aws ec2 describe-vpc-endpoints \
    --filter Name=service-name,Values="com.amazonaws.${REGION}.aps-workspaces" Name=vpc-id,Values=$vpc_id \
    --query 'VpcEndpoints[].DnsEntries[0].DnsName' --profile lqvan --output text)

VPCE_HOSTED_ZONE=$(aws ec2 describe-vpc-endpoints \
    --filter Name=service-name,Values="com.amazonaws.${REGION}.aps-workspaces" Name=vpc-id,Values=$vpc_id \
    --query 'VpcEndpoints[].DnsEntries[0].HostedZoneId' --profile lqvan --output text)

echo "export DNS_NAME=${DNS_NAME}" >> delete.env
echo "export VPCE_HOSTED_ZONE=${VPCE_HOSTED_ZONE}" >> delete.env



cat > dnsentry.json << EOF
{ "Comment": "VPCe record set",
  "Changes": 
  [
      { "Action": "CREATE", 
         "ResourceRecordSet": 
         { 
             "Name": "aps-workspaces.${REGION}.amazonaws.com",
             "Type": "A",
             "AliasTarget": 
             {
                 "DNSName":"${DNS_NAME}",
                 "HostedZoneId":"${VPCE_HOSTED_ZONE}",
                 "EvaluateTargetHealth":true
             }
         }
     }
  ]
}
EOF

# Create DNS record in Private Hosted Zone 
aws route53 change-resource-record-sets \
    --hosted-zone $HOSTED_ZONE \
    --change-batch file://dnsentry.json \
    --profile lqvan

# Authorizes Application Workload Account to issue a request to associate the VPC with a specified hosted zone
application_workload_vpc_id=$(aws cloudformation describe-stacks --stack-name lqvan-app-workload-vpc --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" --profile lqvan --output text)
aws route53 create-vpc-association-authorization \
    --hosted-zone-id $HOSTED_ZONE --vpc VPCRegion=$REGION,VPCId=$application_workload_vpc_id --profile lqvan
    
# Associate Application Workload Account VPC  to Observability Account Private Hosted Zone
aws route53 associate-vpc-with-hosted-zone --hosted-zone-id $HOSTED_ZONE --vpc VPCRegion=$REGION,VPCId=$app_workload_vpc_id \
--comment "For Private Route53 Hosted Zone Access" --profile lqvan

# Update Default Security Group associated with VPCEndpoint to allow traffic from Application workload Account
aws ec2 authorize-security-group-ingress --group-id $DEFAULT_SG --cidr $application_account_cidr --protocol all --profile lqvan
