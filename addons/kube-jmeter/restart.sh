#!/bin/bash
kubectl delete pod -l jmeter_mode=master --force --grace-period=0
kubectl delete pod -l jmeter_mode=slave --force --grace-period=0
