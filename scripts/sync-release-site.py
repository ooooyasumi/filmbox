#!/usr/bin/env python3
"""Prepare a new website version beside the source repository."""
import argparse
import hashlib
import html
import json
import re
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]

def document(title, content):
    blocks = []
    for paragraph in content.split('\n\n'):
        if paragraph.startswith('#'):
            level = min(3,len(paragraph)-len(paragraph.lstrip('#')))
            blocks.append(f'<h{level}>'+html.escape(paragraph.lstrip('# '))+f'</h{level}>')
        else:
            escaped = html.escape(paragraph.replace('`',''))
            escaped = re.sub(r'https?://[A-Za-z0-9./_#?=&%+~-]+', lambda m: '<a href="'+m.group(0)+'" rel="noreferrer">'+m.group(0)+'</a>', escaped)
            blocks.append('<pre>'+escaped+'</pre>')
    return '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+html.escape(title)+' · 菲林盒</title><script src="theme.js"></script><link rel="stylesheet" href="styles.css"><style>main{max-width:850px;margin:40px auto;padding:0 24px 80px}h1,h2,h3{margin:28px 0 14px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.9 system-ui;margin:12px 0}a{text-decoration:underline}nav{padding:24px}</style><nav><a href="index.html">返回菲林盒</a></nav><main>'+''.join(blocks)+'</main></html>'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site',type=Path,required=True,help='Website root containing the preserved v005')
    parser.add_argument('--artifacts',type=Path)
    args = parser.parse_args()
    site = args.site.resolve(); previous=site/'v005'; target=site/'v006'
    if not (previous/'index.html').is_file():
        parser.error('The existing v005 website is required.')
    target.mkdir(exist_ok=True)
    for name in ['index.html','styles.css','app.js','photos.js','reel.js','theme.js','films.js','films.css']:
        text=(previous/name).read_text().replace('assets/','../v005/assets/')
        (target/name).write_text(text)
    config=json.loads((ROOT/'release.json').read_text())
    (target/'release.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    (target/'config.js').write_text('window.FILMBOX_SITE = '+json.dumps({'sourceUrl':config['repositoryUrl'],'feedbackUrl':config['feedbackUrl'],'version':'V6'},ensure_ascii=False,indent=2)+';\n')
    index=(target/'index.html').read_text()
    index=index.replace('Filmbox-0.6.25.zip',config['macos']['asset']).replace('Filmbox-Android-0.4.0-arm64.apk',config['android']['asset'])
    index=index.replace('v0.6.25','v'+config['macos']['version']).replace('v0.4.0','v'+config['android']['version'])
    if config['macos']['distributionStatus']!='notarized':
        index=index.replace('下载 macOS 版','macOS 测试候选包')
    if config['license']['application']=='pending-owner-confirmation':
        index=index.replace('下载 Android 版','Android 测试候选包')
    index=index.replace('</div>\n    </section>\n\n    <section class="brand-finale', '</div><p class="release-help">百度、夸克为实验接入 · NAS 需 WebDAV · <a href="help.html">安装与平台说明</a> · <a href="checksums.txt">校验值</a></p>\n    </section>\n\n    <section class="brand-finale')
    index=index.replace('<footer class="site-footer shell">','<footer class="site-footer shell"><a href="changes.html">更新记录</a><a href="help.html">安装帮助</a><a href="privacy.html">隐私</a><a href="licenses.html">许可</a><a href="capabilities.html">平台与测试状态</a><a href="feedback.html">反馈</a>')
    index=index.replace('<video id="film-player" controls playsinline preload="none"></video>','<video id="film-player" controls playsinline preload="none"></video><p class="film-scope">短片为桌面交互演示。手机端操作及接入条件见<a href="capabilities.html">平台说明</a>。</p>')
    if not args.artifacts:
        for item in [config['macos'],config['android']]:
            index=index.replace('href="downloads/'+item['asset']+'" download','aria-disabled="true" title="候选安装包尚未同步"')
    (target/'index.html').write_text(index)
    with (target/'styles.css').open('a') as out:
        out.write('\n.release-help{font-size:12px;line-height:1.8;margin-top:24px;color:var(--muted);text-align:center}.release-help a{text-decoration:underline}.site-footer{flex-wrap:wrap;gap:16px}.film-scope{font-size:12px;line-height:1.6;padding:10px 18px;color:#bfc3cb;background:#14161a}.film-scope a{text-decoration:underline}\n')
    for name,file in [('privacy','PRIVACY.md'),('help','docs/INSTALL.md'),('capabilities','docs/CAPABILITIES.md')]:
        (target/(name+'.html')).write_text(document(name,(ROOT/file).read_text()))
    license_text=(ROOT/'LICENSE').read_text() if (ROOT/'LICENSE').is_file() else '主项目许可证待负责人确认。'
    (target/'licenses.html').write_text(document('许可',license_text+'\n\n'+(ROOT/'THIRD_PARTY_NOTICES.md').read_text()))
    feedback='# 问题反馈\n\n'+('请通过 '+config['feedbackUrl']+' 提交。' if config['feedbackUrl'] else '公开反馈提交地址待负责人提供。可先按下方模板准备复现资料。')+'\n\n平台和系统版本\n应用版本和设备架构\n本地或云端、提供商及普通／会员条件\n复现步骤\n实际结果和预期结果\n已脱敏的截图或错误代码\n\n提交前移除 Cookie、令牌、密码、私人照片、完整路径与账号信息。'
    (target/'feedback.html').write_text(document('问题反馈',feedback))
    (target/'changes.html').write_text(document('更新记录',(ROOT/'CHANGELOG.md').read_text().split('\n## ',2)[0]+'\n## '+(ROOT/'CHANGELOG.md').read_text().split('\n## ',2)[1]+'\n\n'+(ROOT/'Android/CHANGELOG.md').read_text().split('\n## ',2)[1]))
    sums=[]
    if args.artifacts:
        (target/'downloads').mkdir(exist_ok=True)
        for platform in ['macos','android']:
            name=config[platform]['asset']; source=args.artifacts.resolve()/name
            if not source.is_file():
                parser.error('Missing verified artifact '+name)
            receipt=json.loads((args.artifacts/(platform+'-release.json')).read_text())
            digest=hashlib.file_digest(source.open('rb'),'sha256').hexdigest()
            if digest!=receipt['sha256']:
                parser.error('Artifact differs from its verification receipt '+name)
            shutil.copy2(source,target/'downloads'/name)
            sums.append(digest+'  '+name)
    (target/'checksums.txt').write_text('\n'.join(sums)+'\n')
    history=json.loads((site/'version.json').read_text())
    history.update({'current':'v006','label':'V6','entry':'v006/index.html','sourceUrl':config['repositoryUrl'],'revision':'source-release-preparation'})
    if not any(x.get('version')=='v006' for x in history['history']):
        history['history'].append({'version':'v006','label':'V6','description':'公开源码准备、双平台版本、安装与隐私帮助、测试状态和校验入口。历史网站与原视频保留。'})
    (site/'version.json').write_text(json.dumps(history,ensure_ascii=False,indent=2)+'\n')
    (site/'index.html').write_text('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=v006/"><title>菲林盒</title><a href="v006/">打开菲林盒网站</a></html>\n')
    print(target)

if __name__ == '__main__':
    main()
