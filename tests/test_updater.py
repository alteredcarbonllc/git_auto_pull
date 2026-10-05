import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = next(ROOT.glob('git_auto_*.py'))
spec = importlib.util.spec_from_file_location('updater', MODULE)
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.remote = self.base / 'remote.git'
        self.seed = self.base / 'seed'
        self.local = self.base / 'local'
        self.run_git('init','--bare',str(self.remote))
        self.run_git('clone',str(self.remote),str(self.seed))
        for p in [self.seed]:
            self.run_git('-C',str(p),'config','user.email','test@example.invalid')
            self.run_git('-C',str(p),'config','user.name','Test')
        self.run_git('-C',str(self.seed),'checkout','-b','main')
        (self.seed/'file').write_text('first')
        self.run_git('-C',str(self.seed),'add','file')
        self.run_git('-C',str(self.seed),'commit','-m','first')
        self.run_git('-C',str(self.seed),'push','origin','main')
        self.run_git('clone','-b','main',str(self.remote),str(self.local))
        self.run_git('-C',str(self.local),'config','user.email','test@example.invalid')
        self.run_git('-C',str(self.local),'config','user.name','Test')
    def run_git(self,*args):
        return subprocess.run(['git',*args],check=True,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE).stdout.strip()
    def advance(self,empty=False):
        if not empty:
            (self.seed/'file').write_text('second')
            self.run_git('-C',str(self.seed),'add','file')
        self.run_git('-C',str(self.seed),'commit','--allow-empty','-m','second')
        self.run_git('-C',str(self.seed),'push','origin','main')
    def test_fast_forward_and_noop(self):
        self.assertEqual(u.update(self.local,'main'),'UNCHANGED')
        self.advance()
        self.assertEqual(u.update(self.local,'main'),'UPDATED')
        self.assertEqual((self.local/'file').read_text(),'second')
    def test_same_tree_new_commit(self):
        self.advance(empty=True)
        self.assertEqual(u.update(self.local,'main'),'UPDATED')
    def test_dirty_and_untracked(self):
        (self.local/'file').write_text('dirty')
        with self.assertRaises(ValueError): u.update(self.local,'main')
        self.run_git('-C',str(self.local),'checkout','--','file')
        (self.local/'untracked').write_text('keep')
        with self.assertRaises(ValueError): u.update(self.local,'main')
    def test_wrong_branch(self):
        self.run_git('-C',str(self.local),'checkout','-b','other')
        with self.assertRaises(ValueError): u.update(self.local,'main')
    def test_divergence_preserved(self):
        self.run_git('-C',str(self.local),'commit','--allow-empty','-m','local')
        before=self.run_git('-C',str(self.local),'rev-parse','HEAD')
        self.advance()
        with self.assertRaises(subprocess.CalledProcessError): u.update(self.local,'main')
        self.assertEqual(before,self.run_git('-C',str(self.local),'rev-parse','HEAD'))
    def test_hooks_disabled_and_optin(self):
        hook=self.local/'.git/hooks/post-merge'
        marker=self.base/'hook-ran'
        hook.write_text('#!/bin/sh\ntouch "'+str(marker)+'"\n')
        hook.chmod(0o755)
        self.advance()
        u.update(self.local,'main')
        self.assertFalse(marker.exists())
        self.advance(empty=True)
        u.update(self.local,'main',hooks=True)
        self.assertTrue(marker.exists())
    def test_config_literals(self):
        config=self.base/'config'
        config.write_text('[var]\n$USER="git"\nBOT_TOKEN="a%b=c"\n[projects]\nproject1_path="/tmp/a b"\nproject1_branch="main"\n')
        settings,projects=u.read_config(config)
        self.assertEqual(settings['USER'],'git')
        self.assertEqual(settings['BOT_TOKEN'],'a%b=c')
        self.assertEqual(projects,[('/tmp/a b','main')])
    def test_cli_success_and_failure(self):
        import pwd
        config=self.base/'config'
        lock=self.base/'lock'
        if u.MODE == 'fetch':
            config.write_text(str(self.local)+'\n'+str(self.base/'missing')+'\n')
        else:
            config.write_text('[var]\nGIT_USER='+pwd.getpwuid(os.geteuid()).pw_name+'\n[projects]\nproject1_path='+str(self.local)+'\nproject1_branch=main\nproject2_path='+str(self.base/'missing')+'\nproject2_branch=main\n')
        result=subprocess.run(['python3',str(MODULE),'--config',str(config),'--lock',str(lock)],capture_output=True,text=True)
        self.assertEqual(result.returncode,1)
        self.assertIn(str(self.local),result.stdout)
        self.assertIn('FAILED',result.stderr)

    def test_lock_busy(self):
        import fcntl
        lock=self.base/'lock'
        with lock.open('w') as f:
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            p=subprocess.run(['python3',str(MODULE),'--lock',str(lock),'--config','/nonexistent'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0)
        self.assertIn('SKIPPED',p.stdout)

if __name__ == '__main__': unittest.main()
