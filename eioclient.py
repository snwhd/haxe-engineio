#!/usr/bin/env python3
from multiprocessing import Pool
import engineio

try:
    import tqdm
except Exception:
    print('pip install tqdm for nicer outut')
    tqdm = None


def test_many_target(i=0):
    def end(m):
        success[0] = True
        eio.disconnect()

    eio = engineio.Client(logger=False) # True)
    success = [False]

    try:
        eio.connect('ws://localhost:8080')
        eio.on('message', end);
        eio.wait()
    except engineio.exceptions.ConnectionError:
        pass

    return (i, success[0])


def test_many(count=100, poolcount=10):
    with Pool(poolcount) as pool:
        if tqdm is not None:
            successes = 0
            for i, res in tqdm.tqdm(
                pool.imap_unordered(test_many_target, range(count)),
                total=count
            ):
                if res:
                    successes += 1
            print(f'{successes} / {count} succeeded')
        else:
            for i, res in pool.imap_unordered(main, range(count)):
                res = 'success' if res else 'failed'
                print(f'client {i} {res}')


def test_logs(transport=None):
    if transport is None:
        transports = ['polling', 'websocket']
    else:
        transports = [transport]
    eio = engineio.Client(logger=True) # True)
    eio.connect('ws://localhost:8080', transports=transports)
    eio.wait()


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('test', choices=['many', 'logs'])
    parser.add_argument('--count', type=int, default=100)
    parser.add_argument('--pool', type=int, default=10)
    parser.add_argument('--transport', type=str, default=None)
    args = parser.parse_args()

    if args.test == 'many':
        test_many(args.count, args.pool)
    elif args.test == 'logs':
        test_logs(args.transport)
