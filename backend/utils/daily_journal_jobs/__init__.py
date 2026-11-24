"""Daily journals and insight runs off the request path. Firestore owns state; SQS only wakes the worker.

The package keeps its first job's name: insight runs (`kind=insight`) came later and share the
queue, the records and the worker.
"""
