#!/usr/bin/env python

import argparse
import base64
import json
import logging
import os
import time
import requests
import sys

from time import sleep
from urllib.parse import urlencode
from pprint import pprint

# Created by Chris Lennon VMC SET
# Usage Create- python3 manageSETSDDC.py --rtoken "<refreshtoken>" --org "<orgId>" --provider "ZEROCLOUD" --name "vmc-set-usw-18" --subnet_id "subnet-ea77c4a2" --cidr "10.46.112.0/20"
# Usage Remove - python3 manageSETSDDC.py --rtoken "<refreshtoken>" --org "<orgId>" --name "vmc-set-api-test" --remove 1


def get_args():
    parser = argparse.ArgumentParser(description='Create or Remove SDDC')
    parser.add_argument('--csp', '-c', help='csp host',
                        default='https://console.cloud.vmware.com')
    parser.add_argument('--rtoken', '-t', required=True, help='refresh token')
    parser.add_argument('--org', '-o', required=True, help='org id')
    parser.add_argument('--name', '-n', required=False, help='SDDC Name')
    parser.add_argument('--cidr', '-m', required=False, help='Mgmt CIDR')
    parser.add_argument('--subnet_id', '-s', required=False,
                        help='AWS Subnet')  # subnet-234slj3
    parser.add_argument('--provider', '-p', required=False,
                        help='Provider')  # AWS or ZEROCLOUD
    parser.add_argument('--region', '-g', required=False,
                        help='AWS Region')  # US_WEST_2
    parser.add_argument('--numhost', required=False, help='Number of Hosts')
    parser.add_argument('--networksegment', '-w',
                        required=False, help='Network Segment')
    parser.add_argument('--remove', '-r', required=False, help='remove')
    return parser.parse_args()


def get_token(csp, rtoken):
    data = urlencode({
        'refresh_token': rtoken
    }),
    headers = {"Content-Type": "application/x-www-form-urlencoded",
               'Accept': "application/json"}
    params = {'refresh_token': rtoken}
    resp = requests.post(
        "{host}/csp/gateway/am/api/auth/api-tokens/authorize".format(host=csp), params=params)
    # print(resp.content)
    return resp.json()["access_token"]


def remove_sddc(csp, token, org, name):
    headers = {"csp-auth-token": token, 'Accept': "application/json"}
    params = {'orgID': org}
    resp = requests.get(
        "https://vmc.vmware.com/vmc/api/orgs/{orgId}/sddcs".format(host=csp, orgId=org), headers=headers)
    # print(resp.content)
    #fh = open("removesddc.log","a")
    # fh.write(resp.text)
    # fh.close()
    orgdata = resp.json()
    org_list = orgdata
    for orgs in org_list:
        pprint("Found and removing SDDC: " +
               orgs["name"] + " - " + orgs["resource_config"]["sddc_id"])
        sddcId = orgs["resource_config"]["sddc_id"]
        resp = requests.delete("https://vmc.vmware.com/vmc/api/orgs/{orgId}/sddcs/{sddcId}".format(
            host=csp, orgId=org, sddcId=sddcId), headers=headers)
        # print(resp.content)
        #wait_for_task(org, token, json_response["id"], 60)


def create_sddc(csp, token, org, name, cidr, provider, subnetId, region, numHost, networkSegment):
    headers = {"csp-auth-token": token,
               'Content-Type': "application/json", 'Accept': "application/json"}
    connectedAccount = get_connected_account(org, token)
    data = {
        "name": name,
        "account_link_sddc_config": [
            {
                "customer_subnet_ids": [
                    subnetId
                ],
                "connected_account_id": connectedAccount
            }
        ],
        "vpc_cidr": cidr,
        "provider": provider,
        "sso_domain": "vmc.local",
        "num_hosts": numHost,
        "deployment_type": "SingleAZ",
        "vxlan_subnet": networkSegment,
        "region": region
    }
    resp = requests.post("https://vmc.vmware.com/vmc/api/orgs/{orgId}/sddcs".format(
        host=csp, orgId=org), json=data, headers=headers)
    json_response = resp.json()
    #fh = open("createsddc.log","a")
    # fh.write(resp.text)
    # fh.close()
    # pprint(json_response)
    #pprint(name + " error: " + json_response["error_messages"])
    pprint(name + " " + str(json_response["status"]))
    #wait_for_task(org, token, json_response["id"], 60)


def wait_for_task(orgId, token, task_id, interval_sec=60):

    print('Wait for task {} to finish'.format(task_id))
    print('Checking task status every {} seconds'.format(interval_sec))
    headers = {"csp-auth-token": token, 'Accept': "application/json"}

    while True:
        #task = task_client.get(org_id, task_id)
        resp = requests.get("https://vmc.vmware.com/vmc/api/orgs/{orgId}/tasks/{task_id}".format(
            orgId=orgId, task_id=task_id), headers=headers)
        task = json.loads(resp.text)
        # print(task["status"])

        if task["status"] == "FINISHED":
            print('\nTask {} finished successfully'.format(task_id))
            return True
        elif task["status"] == "FAILED":
            print('\nTask {} failed'.format(task_id))
            return False
        elif task["status"] == "STATUS_CANCELED":
            print('\nTask {} cancelled'.format(task_id))
            return False
        else:
            print("Estimated time remaining: {} minutes".
                  format(task["estimated_remaining_minutes"]))
            sleep(interval_sec)


def get_connected_account(orgId, token):
    headers = {"csp-auth-token": token, 'Accept': "application/json"}
    resp = requests.get(
        "https://vmc.vmware.com/vmc/api/orgs/{orgId}/account-link/connected-accounts".format(orgId=orgId), headers=headers)
    results = json.loads(resp.text)
    for cId in results:
        return cId["id"]


if __name__ == "__main__":
    args = get_args()
    if args.remove is None:
        create_sddc(args.csp, get_token(args.csp, args.rtoken), args.org, args.name, args.cidr,
                    args.provider, args.subnet_id, args.region, args.numhost, args.networksegment)
    if args.remove is '1':
        remove_sddc(args.csp, get_token(
            args.csp, args.rtoken), args.org, args.name)
