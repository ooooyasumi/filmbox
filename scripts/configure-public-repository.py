#!/usr/bin/env python3
"""Connect an owner-provided public GitHub URL to source and feedback links."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    args = parser.parse_args()
    url = args.url.removesuffix('/').removesuffix('.git')
    if not re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',url):
        parser.error('Use the formal HTTPS GitHub repository URL provided by the project owner.')
    current = subprocess.run(['git','-C',str(ROOT),'remote','get-url','origin'],capture_output=True,text=True)
    if current.returncode == 0 and current.stdout.strip().removesuffix('.git') != url:
        parser.error('An existing origin points elsewhere. Review that remote before changing it.')
    config = json.loads((ROOT/'release.json').read_text())
    config['repositoryUrl'] = url
    config['feedbackUrl'] = url+'/issues/new/choose'
    (ROOT/'release.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    links = [f'[版本发布与下载]({url}/releases)', f'[问题反馈]({config["feedbackUrl"]})']
    slug = url.removeprefix('https://github.com/')
    workflow = 'actions/workflows/check.yml'
    badges = [
        f'  <a href="{url}/stargazers"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/{slug}?style=flat-square&amp;color=315bff"></a>',
        f'  <a href="{url}/{workflow}"><img alt="自动检查" src="https://img.shields.io/github/actions/workflow/status/{slug}/check.yml?style=flat-square"></a>',
    ]
    readme = ROOT/'README.md'
    text = readme.read_text()
    text = re.sub(r'<!-- public-links:start -->.*?<!-- public-links:end -->','<!-- public-links:start -->\n'+' · '.join(links)+'\n<!-- public-links:end -->',text,flags=re.S)
    text = re.sub(r'<!-- repository-badges:start -->.*?<!-- repository-badges:end -->',
                  '<!-- repository-badges:start -->\n'+'\n'.join(badges)+'\n  <!-- repository-badges:end -->',text,flags=re.S)
    readme.write_text(text)
    if current.returncode != 0:
        subprocess.run(['git','-C',str(ROOT),'remote','add','origin',url+'.git'],check=True)
    print('Source, badge, releases and feedback links updated.')

if __name__ == '__main__':
    main()
