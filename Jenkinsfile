pipeline {
  agent any

  options {
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  environment {
    IMAGE  = "manojkudocker/trend-app"
    TAG    = "${BUILD_NUMBER}"
    REGION = "us-east-1"
    CLUSTER = "trend-cluster"
  }

  stages {
    stage('Build Image') {
      steps {
        sh 'docker build -t $IMAGE:$TAG -t $IMAGE:latest .'
      }
    }

    stage('Push Image') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
            usernameVariable: 'U', passwordVariable: 'P')]) {
          sh 'echo "$P" | docker login -u "$U" --password-stdin'
          sh 'docker push $IMAGE:$TAG'
          sh 'docker push $IMAGE:latest'
        }
      }
    }

    stage('Deploy to EKS') {
      steps {
        sh 'aws eks update-kubeconfig --name $CLUSTER --region $REGION'
        sh 'kubectl apply -f k8s/'
        sh 'kubectl set image deployment/trend-app trend-app=$IMAGE:$TAG'
        sh 'kubectl rollout status deployment/trend-app --timeout=180s'
        sh 'kubectl get pods,svc'
      }
    }
  }

  post {
    always {
      sh 'docker logout || true'
      sh 'docker image prune -f || true'
    }
    success { echo "Deployed $IMAGE:$TAG to $CLUSTER" }
    failure { echo "Pipeline failed, check the stage logs above" }
  }
}