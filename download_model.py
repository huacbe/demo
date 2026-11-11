from modelscope import snapshot_download
p = snapshot_download('Qwen/Qwen3-Embedding-0.6B', local_dir=r'E:\demo\models\Qwen3-Embedding-0.6B')
print('DL_OK', p)
