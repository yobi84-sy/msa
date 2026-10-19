"""Bounded opt-in validation. Default is a plan; never sends email/SMS directly."""
import argparse,concurrent.futures,json,subprocess,time,urllib.request,uuid
CONTEXT='arn:aws:eks:ap-northeast-2:021158485482:cluster/sales-mall-dev-eks'
def cpu_job(name,workers,duration):
 return {'apiVersion':'batch/v1','kind':'Job','metadata':{'name':name,'namespace':'monitoring','labels':{'yobi-owned-load-test':name}},'spec':{'activeDeadlineSeconds':duration,'ttlSecondsAfterFinished':120,'backoffLimit':0,'parallelism':workers,'completions':workers,'template':{'metadata':{'labels':{'yobi-owned-load-test':name}},'spec':{'restartPolicy':'Never','automountServiceAccountToken':False,'affinity':{'podAntiAffinity':{'requiredDuringSchedulingIgnoredDuringExecution':[{'labelSelector':{'matchLabels':{'yobi-owned-load-test':name}},'topologyKey':'kubernetes.io/hostname'}]}},'containers':[{'name':'bounded-cpu','image':'busybox:1.37.0','command':['sh','-c','while :; do :; done'],'resources':{'requests':{'cpu':'500m','memory':'32Mi'},'limits':{'cpu':'1','memory':'64Mi'}},'securityContext':{'runAsNonRoot':True,'runAsUser':65534,'allowPrivilegeEscalation':False,'capabilities':{'drop':['ALL']}}}]}}}}
def kube(args,payload=None):
 return subprocess.check_output(['kubectl','--context',CONTEXT,*args,'--request-timeout=20s'],input=None if payload is None else json.dumps(payload).encode())
def main():
 p=argparse.ArgumentParser();p.add_argument('--mode',choices=['http','cpu','rds'],required=True);p.add_argument('--duration',type=int,default=300);p.add_argument('--workers',type=int,default=2);p.add_argument('--execute',action='store_true');a=p.parse_args()
 limit=1200 if a.mode=='rds' else 600
 if not 30<=a.duration<=limit or not 1<=a.workers<=(2 if a.mode=='rds' else 6):raise SystemExit('Duration/worker count exceeds the reviewed test bound')
 name='yobi-load-'+uuid.uuid4().hex[:10];job=cpu_job(name,a.workers,a.duration)
 namespace='soldesk' if a.mode=='rds' else 'monitoring'
 if a.mode=='rds':
  job['metadata']['namespace']=namespace;pod=job['spec']['template']['spec'];pod.pop('affinity')
  pod['containers']=[{'name':'read-only-db-cpu','image':'mysql@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b','command':['sh','-c',"while :; do mysql --connect-timeout=5 --ssl-mode=REQUIRED --host=\"$DB_HOST\" --user=admin --execute=\"SET SESSION MAX_EXECUTION_TIME=3000; SELECT BENCHMARK(500000,SHA2('alarm-fixture',256));\" >/dev/null 2>&1 || exit 1; done"],'env':[{'name':key,'valueFrom':{'secretKeyRef':{'name':'my-app-secrets','key':secret}}} for key,secret in [('DB_HOST','DB_HOST'),('MYSQL_PWD','DB_PW')]],'resources':{'requests':{'cpu':'50m','memory':'64Mi'},'limits':{'cpu':'200m','memory':'128Mi'}}}]
 print(json.dumps({'mode':a.mode,'durationSeconds':a.duration,'workers':a.workers,'maxHttpRequestsPerSecond':a.workers*5,'nodeMaximumWillNotBeChanged':True,'dryRun':not a.execute}))
 if not a.execute:
  if a.mode in ('cpu','rds'):print(json.dumps(job,indent=2))
  return
 if input('Type LOAD to approve temporary load, possible autoscaling/DB CPU-credit costs and cleanup of this test Job: ')!='LOAD':raise SystemExit('Cancelled')
 existing=json.loads(kube(['get','jobs','--all-namespaces','-o','json']))
 if any(x['metadata'].get('labels',{}).get('yobi-owned-load-test') for x in existing['items']):raise SystemExit('Another owned load test exists; inspect it first')
 end=time.monotonic()+a.duration
 if a.mode=='http':
  def run_worker():
   ok=bad=0
   while time.monotonic()<end:
    start=time.monotonic()
    try:
     with urllib.request.urlopen('https://server.sy84.store/product-service/product/list',timeout=5) as response:
      if response.status==200:ok+=1
      else:bad+=1
    except Exception:bad+=1
    time.sleep(max(0,.2-(time.monotonic()-start)))
   return ok,bad
  with concurrent.futures.ThreadPoolExecutor(max_workers=a.workers) as pool:results=list(pool.map(lambda _:run_worker(),range(a.workers)))
  print(json.dumps({'success':sum(x[0] for x in results),'failed':sum(x[1] for x in results)}))
 else:
  nodegroup=json.loads(subprocess.check_output(['aws','eks','describe-nodegroup','--cluster-name','sales-mall-dev-eks','--nodegroup-name','sales-mall-dev-nodegroup','--profile','eks-user','--region','ap-northeast-2','--output','json','--no-cli-pager']))
  maximum=nodegroup['nodegroup']['scalingConfig']['maxSize']
  if a.workers>maximum:raise SystemExit('Requested workers exceed the existing node maximum')
  created=json.loads(kube(['create','-f','-','-o','json'],job));uid=created['metadata']['uid']
  try:
   while time.monotonic()<end:
    pods=json.loads(kube(['get','pods','-n',namespace,'-l','yobi-owned-load-test='+name,'-o','json']))
    print(json.dumps({'job':name,'running':sum(x['status']['phase']=='Running' for x in pods['items']),'existingNodeMaximum':maximum}),flush=True)
    time.sleep(min(20,max(0,end-time.monotonic())))
  finally:
   current=json.loads(kube(['get','job',name,'-n',namespace,'-o','json']))
   if current['metadata']['uid']!=uid or current['metadata'].get('labels',{}).get('yobi-owned-load-test')!=name:raise RuntimeError('Job identity changed; cleanup refused')
   # Delete via API UID precondition, avoiding a check/delete race with a replacement.
   process=subprocess.Popen(['kubectl','--context',CONTEXT,'proxy','--port=0'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
   try:
    line=process.stdout.readline();port=int(line.strip().rsplit(':',1)[1])
    body=json.dumps({'apiVersion':'v1','kind':'DeleteOptions','propagationPolicy':'Background','preconditions':{'uid':uid}}).encode()
    req=urllib.request.Request(f'http://127.0.0.1:{port}/apis/batch/v1/namespaces/{namespace}/jobs/{name}',data=body,method='DELETE',headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=15):pass
   finally:process.terminate();process.wait(timeout=10)
   print('Removed only the owned test Job; no HPA or node maximum changed.')
if __name__=='__main__':main()
