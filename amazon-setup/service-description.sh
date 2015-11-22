#!/bin/bash

aws dynamodb create-table --table-name service-description --attribute-definitions AttributeName=Id,AttributeType=S AttributeName=ContainerName,AttributeType=S --key-schema AttributeName=Id,KeyType=HASH --global-secondary-indexes '{"IndexName":"ServiceDescriptionByContainerName","KeySchema":[{"AttributeName":"ContainerName","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"},"ProvisionedThroughput":{"ReadCapacityUnits":1,"WriteCapacityUnits":1{{' --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1
