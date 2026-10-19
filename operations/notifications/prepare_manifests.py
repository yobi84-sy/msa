"""Render the reviewed notification overlay; never applies or sends messages."""
from pathlib import Path
import argparse,copy,hashlib,json,subprocess,textwrap,zipfile
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=Path(__file__).parent/'gitops-overlay');p.add_argument('--max-nodes',type=int,default=6);p.add_argument('--sms-enabled',action='store_true');a=p.parse_args()
if not 1<=a.max_nodes<=20:raise SystemExit('Review node maximum first')
O=a.output;M=O/'msa/k8s/k8s-monitoring';M.mkdir(parents=True,exist_ok=True)
resources=[]
def add(kind,name,spec=None,ns='monitoring',**extra):
 d={'apiVersion':{'Deployment':'apps/v1','ClusterRole':'rbac.authorization.k8s.io/v1','ClusterRoleBinding':'rbac.authorization.k8s.io/v1'}.get(kind,'v1'),'kind':kind,'metadata':{'name':name}}
 if ns:d['metadata']['namespace']=ns
 if spec is not None:d['spec']=spec
 d.update(extra);resources.append(d);return d
def cm(name,data):return add('ConfigMap',name,data=data)
def workload(name,image,port,args,sa='default',mounts=None,volumes=None):
 add('Deployment',name,{'replicas':1,'selector':{'matchLabels':{'app':name}},'template':{'metadata':{'labels':{'app':name}},'spec':{'serviceAccountName':sa,'securityContext':{'runAsNonRoot':True,'runAsUser':65534,'fsGroup':65534},'containers':[{'name':name,'image':image,'args':args,'ports':[{'containerPort':port}],'resources':{'requests':{'cpu':'25m','memory':'48Mi'},'limits':{'cpu':'200m','memory':'192Mi'}},'securityContext':{'allowPrivilegeEscalation':False,'capabilities':{'drop':['ALL']}},'readinessProbe':{'httpGet':{'path':'/-/ready' if name=='yobi-alertmanager' else '/metrics','port':port},'initialDelaySeconds':5,'periodSeconds':10},'volumeMounts':mounts or []}],'volumes':volumes or []}}})
 deployment=resources[-1]
 config_names={v['configMap']['name'] for v in (volumes or []) if 'configMap' in v}
 config_bytes=json.dumps([x['data'] for x in resources if x['kind']=='ConfigMap' and x['metadata']['name'] in config_names],sort_keys=True).encode()
 deployment['spec']['template']['metadata']['annotations']={'yobi.dev/notification-config-sha256':hashlib.sha256(config_bytes).hexdigest()}
 add('Service',name,{'selector':{'app':name},'ports':[{'port':port,'targetPort':port}]})
am=add('ServiceAccount','yobi-alertmanager');am['metadata']['annotations']={'eks.amazonaws.com/role-arn':'arn:aws:iam::021158485482:role/sales-mall-dev-alertmanager-sns'}
order=add('ServiceAccount','order-notifications',ns='soldesk');order['metadata']['annotations']={'eks.amazonaws.com/role-arn':'arn:aws:iam::021158485482:role/sales-mall-dev-ordering-sns'}
add('ConfigMap','order-notifications',ns='soldesk',data={'ORDER_ALERTS_ENABLED':'true','ORDER_ALERT_EMAIL_TOPIC_ARN':'arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-orders-email','ORDER_ALERT_SMS_TOPIC_ARN':'arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-orders-sms' if a.sms_enabled else '', 'ORDER_ALERT_SMS_DAILY_LIMIT':'10'})
add('ServiceAccount','yobi-kube-state')
add('ClusterRole','yobi-kube-state',ns=None,rules=[{'apiGroups':[''],'resources':['nodes','pods'],'verbs':['get','list','watch']},{'apiGroups':['apps'],'resources':['deployments','replicasets','statefulsets','daemonsets'],'verbs':['get','list','watch']},{'apiGroups':['autoscaling'],'resources':['horizontalpodautoscalers'],'verbs':['get','list','watch']},{'apiGroups':['apiextensions.k8s.io'],'resources':['customresourcedefinitions'],'verbs':['get','list','watch']},{'apiGroups':['argoproj.io'],'resources':['applications'],'verbs':['get','list','watch']}])
add('ClusterRoleBinding','yobi-kube-state',ns=None,roleRef={'apiGroup':'rbac.authorization.k8s.io','kind':'ClusterRole','name':'yobi-kube-state'},subjects=[{'kind':'ServiceAccount','name':'yobi-kube-state','namespace':'monitoring'}])
custom={'kind':'CustomResourceStateMetrics','spec':{'resources':[{'groupVersionKind':{'group':'argoproj.io','version':'v1alpha1','kind':'Application'},'labelsFromPath':{'name':['metadata','name']},'metrics':[{'name':'application_info','help':'Argo application health and sync state','each':{'type':'Info','info':{'labelsFromPath':{'health':['status','health','status'],'sync':['status','sync','status']}}}}]}]}}
cm('yobi-kube-state-config',{'custom.yml':json.dumps(custom)})
workload('yobi-kube-state','registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.15.0',8080,['--resources=nodes,pods,deployments,replicasets,statefulsets,daemonsets,horizontalpodautoscalers','--metric-labels-allowlist=nodes=[eks.amazonaws.com/nodegroup]','--custom-resource-state-config-file=/config/custom.yml'], 'yobi-kube-state',[{'name':'config','mountPath':'/config','readOnly':True}],[{'name':'config','configMap':{'name':'yobi-kube-state-config'}}])
cm('yobi-blackbox',{'blackbox.yml':json.dumps({'modules':{'https_2xx':{'prober':'http','timeout':'10s','http':{'method':'GET','valid_status_codes':[200],'fail_if_not_ssl':True,'preferred_ip_protocol':'ip4'}}}})})
workload('yobi-blackbox','prom/blackbox-exporter:v0.26.0',9115,['--config.file=/config/blackbox.yml'],mounts=[{'name':'config','mountPath':'/config','readOnly':True}],volumes=[{'name':'config','configMap':{'name':'yobi-blackbox'}}])
alertmanager={'global':{'resolve_timeout':'5m'},'route':{'receiver':'sns-email','group_by':['alertname','namespace','service'],'group_wait':'30s','group_interval':'5m','repeat_interval':'30m'},'receivers':[{'name':'sns-email','sns_configs':[{'topic_arn':'arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts','sigv4':{'region':'ap-northeast-2'},'send_resolved':True,'message':'{{ range .Alerts }}[{{ .Status }}] {{ .Labels.alertname }}: {{ .Annotations.summary }}\n{{ end }}'}]}]}
cm('yobi-alertmanager',{'alertmanager.yml':json.dumps(alertmanager)})
workload('yobi-alertmanager','prom/alertmanager:v0.28.1',9093,['--config.file=/config/alertmanager.yml','--storage.path=/data','--cluster.listen-address='],'yobi-alertmanager',[{'name':'config','mountPath':'/config','readOnly':True},{'name':'data','mountPath':'/data'}],[{'name':'config','configMap':{'name':'yobi-alertmanager'}},{'name':'data','emptyDir':{}}])
rules=[]
def rule(name,expr,duration,summary,severity='warning'):
 rules.append({'alert':name,'expr':expr,'for':duration,'labels':{'severity':severity},'annotations':{'summary':summary}})
rule('StorefrontUnavailable','probe_success{job="yobi-public-https"} == 0','3m','Shopping site or product API unavailable','critical')
rule('StorefrontProbeMissing','absent(probe_success{job="yobi-public-https"})','3m','HTTPS monitoring has no samples','critical')
rule('AppHasNoReadyReplicas','kube_deployment_status_replicas_available{namespace="soldesk",deployment=~"(apigateway|member|product|ordering|frontend)-depl"} == 0','2m','Application has no ready replicas','critical')
rule('PodRestarting','sum by(namespace,pod)(increase(kube_pod_container_status_restarts_total{namespace=~"soldesk|monitoring"}[10m])) >= 3','1m','Container restarted at least three times in ten minutes')
rule('NodeNotReady','kube_node_status_condition{condition="Ready",status="true"} == 0','3m','Kubernetes node is not Ready','critical')
rule('NodeMemoryHigh','1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes > 0.9','5m','Node memory exceeds ninety percent')
rule('ArgoSyncFailed','kube_customresource_application_info{name=~"msa-root|yobi-v1-msa|msa-monitoring",sync!="Synced"} == 1','5m','Argo application is not synced')
rule('ArgoAppUnhealthy','kube_customresource_application_info{name=~"msa-root|yobi-v1-msa|msa-monitoring",health=~"Degraded|Missing|Unknown|Progressing"} == 1','5m','Argo application is unhealthy')
rule('HpaAtMaximum','kube_horizontalpodautoscaler_status_desired_replicas{namespace="soldesk"} >= kube_horizontalpodautoscaler_spec_max_replicas{namespace="soldesk"}','5m','HPA has reached its configured maximum')
rule('NodeCapacityAtMaximum',f'count(kube_node_labels{{label_eks_amazonaws_com_nodegroup="sales-mall-dev-nodegroup"}}) >= {a.max_nodes}','5m','Node group has reached the reviewed node maximum')
rule('StateMetricsUnavailable','up{job="yobi-kube-state"} == 0','3m','Kubernetes state collector unavailable')
rule('OrderNotificationDeliveryFailing','sum(increase(order_notification_events_total{result="failed"}[10m])) > 0','1m','Order notification delivery failed; inspect outbox')
cm('yobi-alert-rules',{'rules.yml':json.dumps({'groups':[{'name':'yobi-operational','rules':rules}]})})
# Keep the existing Prometheus data source and API-proxy cAdvisor configuration.
base=(R/'msa/k8s/k8s-monitoring/prometheus-config.yml').read_text(encoding='utf-8-sig')
config=textwrap.dedent(base.split('  prometheus.yml: |\n',1)[1])
config+='''
  - job_name: yobi-kube-state
    static_configs:
      - targets: [yobi-kube-state.monitoring.svc:8080]
  - job_name: yobi-order-notifications
    metrics_path: /actuator/prometheus
    static_configs:
      - targets: [ordering-service.soldesk.svc:80]
  - job_name: yobi-public-https
    scrape_interval: 60s
    metrics_path: /probe
    params:
      module: [https_2xx]
    static_configs:
      - targets: [https://server.sy84.store/, https://server.sy84.store/product-service/product/list]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: yobi-blackbox.monitoring.svc:9115
alerting:
  alertmanagers:
    - static_configs:
        - targets: [yobi-alertmanager.monitoring.svc:9093]
rule_files: [/etc/yobi-alerts/rules.yml]
'''
config=config.replace('--resources=','--resources=')
cm('prometheus-config',{'prometheus.yml':config})
raw=subprocess.check_output(['kubectl','create','--dry-run=client','--validate=false','-f',str(R/'msa/k8s/k8s-monitoring/prometheus-depl_svc.yml'),'-o','json']).decode('utf-8-sig');items=[];decoder=json.JSONDecoder()
while raw.strip():
 doc,end=decoder.raw_decode(raw.lstrip());items.extend(doc.get('items',[doc]));raw=raw.lstrip()[end:]
deployment=next(x for x in items if x['kind']=='Deployment');pod=deployment['spec']['template']['spec']
deployment['spec']['template'].setdefault('metadata',{}).setdefault('annotations',{})['yobi.dev/notification-config-sha256']=hashlib.sha256((config+json.dumps(rules,sort_keys=True)).encode()).hexdigest()
pod.setdefault('volumes',[]).append({'name':'yobi-alert-rules','configMap':{'name':'yobi-alert-rules'}})
pod['containers'][0].setdefault('volumeMounts',[]).append({'name':'yobi-alert-rules','mountPath':'/etc/yobi-alerts','readOnly':True})
for item in items:resources.append(item)
# Split owned new resources from modifications to Argo-owned manifests.
existing={'prometheus-config','prometheus'}
new=[x for x in resources if x not in items and x['metadata']['name']!='prometheus-config']
(M/'alerts-resources.yml').write_text(json.dumps({'apiVersion':'v1','kind':'List','items':new},indent=2),encoding='utf-8')
(M/'prometheus-config.yml').write_text(json.dumps(next(x for x in resources if x['kind']=='ConfigMap' and x['metadata']['name']=='prometheus-config'),indent=2),encoding='utf-8')
(M/'prometheus-depl_svc.yml').write_text(json.dumps({'apiVersion':'v1','kind':'List','items':items},indent=2),encoding='utf-8')
k=(R/'msa/k8s/k8s-monitoring/kustomization.yaml').read_text(encoding='utf-8-sig')
(M/'kustomization.yaml').write_text(k+'\n  - alerts-resources.yml\n',encoding='utf-8')
print('Rendered notification overlay. No AWS changes, Git publish, email or SMS executed.')
# Reproducible, dependency-free Lambda package; AWS supplies boto3 at runtime.
with zipfile.ZipFile(Path(__file__).parent/'terraform/external-probe.zip','w',zipfile.ZIP_DEFLATED) as bundle:
 entry=zipfile.ZipInfo('external_probe.py',date_time=(2026,10,18,0,0,0));entry.compress_type=zipfile.ZIP_DEFLATED;bundle.writestr(entry,(Path(__file__).parent/'external_probe.py').read_bytes())
