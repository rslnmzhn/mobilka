#ifndef RUNNER_DOCUMENT_WORKER_BROKER_H_
#define RUNNER_DOCUMENT_WORKER_BROKER_H_

#include <flutter/binary_messenger.h>

void RegisterDocumentWorkerBroker(flutter::BinaryMessenger* messenger);
void StopDocumentWorkerBroker();

#endif
