"""Apply an explicitly dispatched review patch without publishing a release."""
import base64
import gzip
import os
import subprocess

patch = gzip.decompress(base64.b64decode(os.environ["REVIEW_PATCH"], validate=True))
subprocess.run(["git", "apply", "--check"], input=patch, check=True)
subprocess.run(["git", "apply"], input=patch, check=True)
