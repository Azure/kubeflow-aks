---
categories: ["prerequisites"]
tags: ["docs"]
title: "Deployment Options"
linkTitle: "Deployment Options"
date: 2023-03-07
description: >
  Deploy Kubeflow into AKS
---

If you want to deploy Kubeflow with minimal changes on AKS, then consider the [vanilla]({{< ref "/docs/Deployment Options/vanilla-installation" >}}) deployment option. The Kubeflow control plane is installed on Azure Kubernetes Service (AKS), which is a managed container service used to run and scale Kubernetes applications in the cloud.

For a more secure deployment option that is has minimum baseline security, then consider the [deploy with custom password and TLS] deployment option. 