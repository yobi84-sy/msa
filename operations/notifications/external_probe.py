"""Lambda HTTPS probe independent of EKS. No credentials or customer data logged."""
import json,urllib.request
import boto3
TARGETS=('https://server.sy84.store/','https://server.sy84.store/product-service/product/list')
def check_targets(opener=urllib.request.urlopen):
 for url in TARGETS:
  try:
   with opener(url,timeout=5) as response:
    if response.status!=200:return 0
    if url.endswith('/list') and not isinstance(json.loads(response.read(1024*1024)),list):return 0
  except Exception:return 0
 return 1
def handler(event,context):
 available=check_targets()
 boto3.client('cloudwatch').put_metric_data(Namespace='Yobi/Availability',MetricData=[{'MetricName':'HttpsAvailable','Dimensions':[{'Name':'Project','Value':'sales-mall-dev'}],'Value':available,'Unit':'Count'}])
 return {'available':available}
