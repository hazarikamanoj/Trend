# Trend App: Production Deployment on AWS EKS

Docker · Terraform · DockerHub · Amazon EKS · Jenkins CI/CD · Prometheus & Grafana

A prebuilt React (Vite) application is containerised, provisioned onto AWS with Terraform, built and pushed by a Jenkins pipeline that is triggered by every GitHub commit, and deployed to an Amazon EKS cluster behind a Kubernetes LoadBalancer. The cluster is monitored with Prometheus and Grafana.

---

## 1. Submission details

| Item | Value |
|---|---|
| GitHub repository | https://github.com/hazarikamanoj/Trend |
| Source repository (forked) | https://github.com/Vennilavanguvi/Trend |
| DockerHub image | `manojkudocker/trend-app` (tags `1` to `4`, `latest`) |
| AWS region | `us-east-1` (N. Virginia) |
| EKS cluster | `trend-cluster` (2 worker nodes) |
| Application port | `3000` inside the container; the load balancer listens on `80` and forwards to `3000` |
| Load balancer DNS | `a80917ceb4b544ea28eb240f122deed5-686817863.us-east-1.elb.amazonaws.com` |
| **Load balancer ARN** | `arn:aws:elasticloadbalancing:us-east-1:775711761772:loadbalancer/a80917ceb4b544ea28eb240f122deed5` |
| Load balancer type | Classic Load Balancer (see section 7) |
| Jenkins server | EC2 instance created by Terraform, UI on port `8080` |

The AWS resources were torn down after the evidence was captured, so the URLs above are no longer live. All proof of the working system is in the screenshots in section 9.

---

## 2. Architecture

```
Developer ──git push──▶ GitHub ──webhook──▶ Jenkins (EC2, created by Terraform)
                                               │
                                  1. docker build  (nginx serving dist/ on 3000)
                                  2. docker push   ──▶ DockerHub (manojkudocker/trend-app)
                                  3. kubectl apply + set image + rollout status
                                               │
                                               ▼
                         Amazon EKS (trend-cluster, us-east-1)
                         Deployment: 2 pods ──▶ Service type LoadBalancer ──▶ Internet
                                               │
                              Prometheus + Grafana (namespace: monitoring)
```

---

## 3. Repository structure

```
Trend/
├── dist/                  # prebuilt React application (from the source repo)
├── k8s/
│   ├── deployment.yaml    # 2 replicas, probes, resource limits, rolling update
│   └── service.yaml       # LoadBalancer, port 80 -> container port 3000
├── terraform/
│   ├── main.tf            # VPC, subnet, IGW, route table, security group, IAM, EC2
│   └── jenkins-install.sh # user_data: installs Jenkins, Docker, AWS CLI, kubectl
├── Dockerfile
├── nginx.conf             # nginx listens on port 3000
├── Jenkinsfile            # declarative pipeline
├── .dockerignore
├── .gitignore
├── .gitattributes
├── screenshots/           # evidence referenced in this README
└── README.md
```

---

## 4. Setup instructions

### 4.1 Prerequisites

AWS account with an IAM user (`aws configure` done), Git, Docker, Terraform, `kubectl`, `eksctl`, Helm, a GitHub account and a DockerHub account.

### 4.2 Get the application

The repository contains only the production build (`dist/`), so no `npm install` or build step is needed.

```bash
git clone https://github.com/Vennilavanguvi/Trend.git
cd Trend
ls dist
```

### 4.3 Dockerize

`Dockerfile`:

```dockerfile
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist /usr/share/nginx/html
EXPOSE 3000
CMD ["nginx", "-g", "daemon off;"]
```

`nginx.conf` makes nginx listen on port 3000 and serve `index.html` for all routes:

```nginx
server {
  listen 3000;
  root /usr/share/nginx/html;
  index index.html;
  location / { try_files $uri /index.html; }
}
```

Build and test locally:

```bash
docker build -t trend-app .
docker run -d --name trend-test -p 3000:3000 trend-app
curl -I http://localhost:3000        # HTTP/1.1 200 OK
```

### 4.4 DockerHub

Create the repository `manojkudocker/trend-app` (public) on hub.docker.com, then:

```bash
docker login
docker tag trend-app manojkudocker/trend-app:latest
docker push manojkudocker/trend-app:latest
```

### 4.5 Version control

`.gitignore` excludes Terraform state and providers, key files and environment files. `.dockerignore` keeps the build context small.

```bash
git add .
git commit -m "Add Dockerfile, k8s manifests, Terraform, Jenkinsfile"
git push origin main
```

### 4.6 Infrastructure with Terraform

`terraform/main.tf` defines a VPC (`10.0.0.0/16`), a public subnet, an internet gateway and route table, a security group (SSH from my IP, Jenkins UI on `8080`), an IAM role and instance profile for the Jenkins server (permission to describe EKS clusters), and the Ubuntu 22.04 EC2 instance that installs Jenkins, Docker, the AWS CLI and `kubectl` through `jenkins-install.sh`.

```bash
aws ec2 create-key-pair --region us-east-1 --key-name trend-key \
  --query 'KeyMaterial' --output text > trend-key.pem
chmod 400 trend-key.pem

cd terraform
terraform init
terraform plan  -var="my_ip=<my-ip>/32" -var="key_name=trend-key"
terraform apply -var="my_ip=<my-ip>/32" -var="key_name=trend-key"
```

Outputs: `jenkins_public_ip`, `jenkins_url`, `jenkins_role_arn`. The instance type is `m7i-flex.large`, which is eligible for the free plan on this account.

### 4.7 Amazon EKS

```bash
eksctl create cluster \
  --name trend-cluster --region us-east-1 \
  --zones us-east-1a,us-east-1b \
  --nodegroup-name workers --node-type m7i-flex.large --nodes 2

aws eks update-kubeconfig --name trend-cluster --region us-east-1
kubectl get nodes
```

Allow the Jenkins server's IAM role to use the cluster:

```bash
ROLE_ARN=$(terraform output -raw jenkins_role_arn)
eksctl create iamidentitymapping --cluster trend-cluster --region us-east-1 \
  --arn "$ROLE_ARN" --username jenkins --group system:masters
```

### 4.8 Kubernetes manifests

`k8s/deployment.yaml` runs 2 replicas with a rolling update (`maxUnavailable: 0`), readiness and liveness probes on port 3000, and CPU and memory requests and limits. `k8s/service.yaml` is a `LoadBalancer` service that maps port `80` to the container port `3000`.

```bash
kubectl apply -f k8s/
kubectl get pods,svc,deployments
```

### 4.9 Jenkins

1. Open `http://<jenkins_public_ip>:8080` and unlock it with `/var/lib/jenkins/secrets/initialAdminPassword`.
2. Install the suggested plugins, then **Docker Pipeline** and **Kubernetes CLI** (Git, GitHub and Pipeline come with the suggested set).
3. Add the credential `dockerhub-creds` (username with password; the password is a DockerHub access token).
4. Create a Pipeline job `trend-pipeline`: *Pipeline script from SCM*, Git, repository `https://github.com/hazarikamanoj/Trend.git`, branch `*/main`, script path `Jenkinsfile`, and tick **GitHub hook trigger for GITScm polling**.

### 4.10 GitHub webhook

Repository **Settings → Webhooks → Add webhook**: payload URL `http://<jenkins_public_ip>:8080/github-webhook/`, content type `application/json`, event: push. A green tick with a `200` response confirms Jenkins received it, and every push to `main` now starts a build.

### 4.11 Monitoring

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.service.type=NodePort --set grafana.service.nodePort=32000
kubectl get pods -n monitoring
```

Grafana and Prometheus were opened through port-forwards (`svc/monitoring-grafana` on 3001, `svc/monitoring-kube-prometheus-prometheus` on 9090). The dashboards used are *Kubernetes / Compute Resources / Cluster*, *Namespace (Pods)* and *Node Exporter / Nodes*.

---

## 5. Pipeline explanation (`Jenkinsfile`)

The pipeline is declarative and runs on the Jenkins server. Environment variables: `IMAGE=manojkudocker/trend-app`, `TAG=${BUILD_NUMBER}`, `REGION=us-east-1`, `CLUSTER=trend-cluster`. Options: a 20 minute timeout and no concurrent builds.

| Stage | What it does |
|---|---|
| Checkout SCM | Jenkins fetches the repository and the `Jenkinsfile` from GitHub. |
| Build Image | `docker build -t $IMAGE:$TAG -t $IMAGE:latest .` |
| Push Image | Logs in to DockerHub with the `dockerhub-creds` credential (the token is masked in the log) and pushes both the build-number tag and `latest`. |
| Deploy to EKS | `aws eks update-kubeconfig`, `kubectl apply -f k8s/`, `kubectl set image deployment/trend-app trend-app=$IMAGE:$TAG`, then `kubectl rollout status` so the stage fails if the new pods do not become ready. Finally it prints `kubectl get pods,svc`. |
| Post actions | `docker logout` and `docker image prune -f` to remove credentials and free disk space. |

Deploying the exact build-number tag (instead of relying on `latest`) makes every rollout traceable to a build. Because the readiness probe checks port 3000, a successful rollout proves the application is serving on that port. Builds #1 to #4 all finished `SUCCESS`; builds #2 to #4 were started automatically by GitHub pushes.

---

## 6. Application endpoint

After the Deploy stage, `kubectl get svc trend-service` shows the load balancer hostname listed in section 1. The page is served by nginx from the pods and reached through the load balancer on port 80, which forwards to port 3000 on the pods.

---

## 7. Load balancer note

The service was first created with the annotation `service.beta.kubernetes.io/aws-load-balancer-type: "nlb"` to get a Network Load Balancer. AWS rejected it with:

```
CreateLoadBalancer ... OperationNotPermitted: This AWS account currently does not
support creating load balancers.
```

The error comes from the Elastic Load Balancing v2 API (NLB/ALB), which was not yet enabled for the account while its verification was still in progress. A Classic Load Balancer uses the older API and worked, so the annotation was removed and the service now provisions a Classic Load Balancer. A Classic Load Balancer does not show an ARN field in the console, so the ARN in section 1 follows the documented format `arn:aws:elasticloadbalancing:<region>:<account-id>:loadbalancer/<load-balancer-name>`, using the name returned by `aws elb describe-load-balancers`. The event is shown in the screenshots.

---

## 8. Issues faced and how they were fixed

| Issue | Fix |
|---|---|
| EC2 `t3.medium` rejected as not free-tier eligible | Listed eligible types with `describe-instance-types --filters free-tier-eligible=true` and used `m7i-flex.large`. |
| Jenkins apt repository reported an unsigned repository (`NO_PUBKEY`) | The Jenkins signing key had been rotated; replaced the old key with the current 2026 key. |
| Jenkins service failed to start after installation | Installed the Java version Jenkins requires (OpenJDK 21) and restarted the service. |
| Jenkins could not reach EKS | Mapped the Jenkins IAM role into the cluster with `eksctl create iamidentitymapping`. |
| NLB creation blocked (`OperationNotPermitted`) | Used a Classic Load Balancer (section 7). |
| Unstable connection from my network to the cluster API and Jenkins UI | Reached Jenkins and Grafana through an SSH tunnel (`ssh -L`) to the Jenkins server. |
| SSH key path with a space (`Project 2`) split the argument | Used a relative path or quoted the full path. |

---

## 9. Clean-up

After the screenshots were captured, the stack was destroyed in this order, so that the load balancer's network interfaces did not block the VPC deletion:

```bash
kubectl delete svc trend-service
helm uninstall monitoring -n monitoring
eksctl delete cluster --name trend-cluster --region us-east-1
cd terraform && terraform destroy -var="my_ip=<my-ip>/32" -var="key_name=trend-key"
```

---

## 10. Screenshots

### 10.1 Application and Docker

**01: Cloned repository with the `dist` folder**

![01 dist folder](screenshots/01-index_js_dist_terminal.PNG)

**02: `.gitignore`**

![02 gitignore](screenshots/02-gitignore.PNG)

**03: `Dockerfile`**

![03 Dockerfile](screenshots/03-Dockerfile.PNG)

**04: `.dockerignore`**

![04 dockerignore](screenshots/04-dockerignore.PNG)

**05: `docker pull`, `docker run` and `docker ps` showing `trend-test` up on port 3000**

![05 docker run and ps](screenshots/05-docker_pull_run_ps.PNG)

**06: `docker build` output**

![06 docker build](screenshots/06-DockerBuildTerminal.PNG)

**07: Docker Desktop with the `trend-test` container running on 3000:3000**

![07 Docker Desktop](screenshots/07-docker_desktop_trend-test.PNG)

**08: Application loaded at `http://localhost:3000`**

![08 app on localhost](screenshots/08-httpLocalhost3000_with_the_appLoaded.PNG)

### 10.2 DockerHub

**09: DockerHub repository tags (1 of 2)**

![09 DockerHub tags](screenshots/09-dockerhub_tags_a.PNG)

**10: DockerHub repository tags (2 of 2)**

![10 DockerHub tags](screenshots/10-dockerhub_tags_b.PNG)

### 10.3 Git and GitHub

**11: Git commands in the terminal**

![11 Git CLI](screenshots/11-GitHubCLI_Terminal.PNG)

**12: `git push` to GitHub**

![12 git push](screenshots/12-GitHub_push.png)

**13: GitHub repository contents**

![13 GitHub repo](screenshots/13-GitHubRepo.PNG)

**14: Commit history**

![14 commits](screenshots/14-GitHub_commits.PNG)

### 10.4 Terraform and AWS infrastructure

**15: `main.tf`**

![15 main.tf](screenshots/15-main.tf.png)

**16: `terraform output` and `terraform state list`**

![16 terraform output](screenshots/16-terraform_output_state-list.PNG)

**17: VPC**

![17 VPC](screenshots/17-VPC.PNG)

**18: VPC resource map**

![18 VPC resource map](screenshots/18-VPC_resource_map_Q.PNG)

**19: `jenkins-sg` inbound rules**

![19 security group](screenshots/19-jenkins-sg_inbound_rules.PNG)

**20: `jenkins-role` IAM role**

![20 IAM role](screenshots/20-jenkins-role_IAM_role_page.PNG)

**21: Jenkins EC2 instance running**

![21 EC2 instance](screenshots/21-EC2_Jenkins_server_instance.PNG)

### 10.5 Amazon EKS and Kubernetes

**22: EKS cluster `trend-cluster` active**

![22 EKS cluster](screenshots/22-EKS_Cluster.PNG)

**23: `kubectl get nodes -o wide`**

![23 nodes](screenshots/23-kubectl_get_nodes-o_wide.PNG)

**24: `deployment.yaml` (1 of 2)**

![24 deployment a](screenshots/24-deployment.yaml_a.PNG)

**25: `deployment.yaml` (2 of 2)**

![25 deployment b](screenshots/25-deployment.yaml_b.PNG)

**26: `service.yaml`**

![26 service](screenshots/26-service.yaml_.PNG)

**27: Pods running and the load balancer hostname**

![27 pods and service](screenshots/27-pods_Running_load_balancer_hostname.PNG)

**28: Deployed image tag (1 of 2)**

![28 image tag a](screenshots/28-image_tag_a.PNG)

**29: Deployed image tag (2 of 2)**

![29 image tag b](screenshots/29-image_tag_b.PNG)

**30: Application open in the browser through the load balancer**

![30 app in browser](screenshots/30-app_on_browser.PNG)

### 10.6 Load balancer and ARN

**31: Load balancer ARN evidence**

![31 ARN evidence](screenshots/31-ARN_evidence.PNG)

**32: Load Balancers page in the EC2 console**

![32 load balancers console](screenshots/32-Load_Balancers_console_page.PNG)

**33: Classic Load Balancer created by the service**

![33 classic load balancer](screenshots/33-recreated_ClassicLB.PNG)

### 10.7 Jenkins

**34: Git and GitHub plugins installed**

![34 Git plugins](screenshots/34-Git_plugin.PNG)

**35: Docker plugins installed**

![35 Docker plugins](screenshots/35-Docker_plugin.PNG)

**36: Kubernetes plugins installed**

![36 Kubernetes plugins](screenshots/36-Kubernetes_Plugin.PNG)

**37: `dockerhub-creds` credential (secret masked)**

![37 credentials](screenshots/37-Jenkins_credentialsID.PNG)

**38: Job configuration: webhook trigger and SCM (1 of 2)**

![38 job config a](screenshots/38-Jenkins_configuration.PNG)

**39: Job configuration: branch and script path (2 of 2)**

![39 job config b](screenshots/39-Jenkins_configuration_b.PNG)

**40: Build history, builds #1 to #4**

![40 build history](screenshots/40-Jenkins_build_history.PNG)

**41: `Jenkinsfile` (1 of 2)**

![41 Jenkinsfile a](screenshots/41-Jenkinsfile_terminal.PNG)

**42: `Jenkinsfile` (2 of 2)**

![42 Jenkinsfile b](screenshots/42-Jenkinsfile_terminal_b.PNG)

**43: Build #4 console output ("Started by GitHub push" through `Finished: SUCCESS`)**

![43 console build 4](screenshots/43-Jenkins_console_build_4.png)

**49: Pipeline stage view**

![49 pipeline](screenshots/49-Jenkins_pipeline.PNG)

### 10.8 GitHub webhook

**44: Webhook `push` delivery with a `200` response**

![44 push delivery](screenshots/44-webhook_push_delivery.png)

**45: Webhook `ping` redelivery with a `200` response**

![45 ping redelivery](screenshots/45-webhook_ping_redelivery.png)

**46: Webhook delivery list**

![46 delivery list](screenshots/46-webhook_delivery_list.png)

**47: Webhook settings with the payload URL**

![47 payload URL](screenshots/47-webhook_payloadURL.PNG)

### 10.9 Final cluster state and monitoring

**48: `kubectl get pods`**

![48 pods](screenshots/48-kubectl_get_pods.PNG)

**50: Grafana port-forward**

![50 Grafana forwarding](screenshots/50-Grafana_forwarding.png)

**51: Grafana, Kubernetes / Compute Resources / Cluster**

![51 Grafana cluster](screenshots/51-Grafana_k8s_compute_resources_cluster.png)

**52: Grafana, Node Exporter / Nodes**

![52 Grafana nodes](screenshots/52-Grafana_node_exporter_nodes.png)

**53: Prometheus targets, all UP**

![53 Prometheus targets](screenshots/53-Prometheus_targetsUP.png)
