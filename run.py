# run.py

import os

from app import app

if __name__ == '__main__':
    # Bind to 0.0.0.0 so the app is reachable from outside a container;
    # this is the only behavioral change made to the original app, and
    # local usage on the host is unaffected (0.0.0.0 still answers on
    # localhost/127.0.0.1).
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port)

