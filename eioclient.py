#!/usr/bin/env python3
from multiprocessing import Pool
import engineio

try:
    import tqdm
except Exception:
    print('pip install tqdm for nicer outut')
    tqdm = None


def main(i=0):
    eio = engineio.Client(logger=False) # True)

    success = [False]

    def end(m, success):
        success[0] = True
        eio.disconnect()

    try:
        eio.connect('ws://localhost:8080')
        eio.on('message', lambda m: end(m, success))
        eio.wait()
    except engineio.exceptions.ConnectionError:
        pass

    return (i, success[0])


count = 100;
with Pool(12) as pool:
    if tqdm is not None:
        successes = 0
        for i, res in tqdm.tqdm(pool.imap_unordered(main, range(count)), total=count):
            if res:
                successes += 1
        print(f'{successes} / {count} succeeded')
    else:
        for i, res in pool.imap_unordered(main, range(count)):
            res = 'success' if res else 'failed'
            print(f'client {i} {res}')
