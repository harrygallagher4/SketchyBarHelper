#pragma once

#include <mach/mach.h>
#include <mach/message.h>
#include <bootstrap.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdio.h>

typedef char* env;

#define MACH_HANDLER(name) void name(env env)
typedef MACH_HANDLER(mach_handler);

struct mach_message {
  mach_msg_header_t header;
  mach_msg_size_t msgh_descriptor_count;
  mach_msg_ool_descriptor_t descriptor;
};

struct mach_buffer {
  struct mach_message message;
  mach_msg_trailer_t trailer;
};

struct mach_server {
  bool is_running;
  mach_port_name_t task;
  mach_port_t port;
  mach_port_t bs_port;

  pthread_t thread;
  mach_handler* handler;
};

struct key_value_pair {
  char* key;
  char* value;
};

static struct mach_server g_mach_server;
static mach_port_t g_mach_port = 0;

static inline char* env_get_value_for_key(env env, char* key) {
  uint32_t caret = 0;
  for(;;) {
    if (!env[caret]) break;
    if (strcmp(&env[caret], key) == 0)
      return &env[caret + strlen(&env[caret]) + 1];

    caret += strlen(&env[caret])
             + strlen(&env[caret + strlen(&env[caret]) + 1])
             + 2;
  }
  return (char*)"";
}

static inline struct key_value_pair env_get_next_key_value_pair(env env, struct key_value_pair prev) {
  uint32_t caret = 0;
  if (prev.key != NULL) {
    caret = (prev.key - env) + strlen(&env[(prev.key - env)])
                             + strlen(&env[(prev.key - env)
                                      + strlen(&env[(prev.key - env)])
                                      + 1                             ])
                             + 2;
  }

  if (!env[caret]) return (struct key_value_pair) { NULL, NULL };

  return (struct key_value_pair) { env + caret,
                                   env + caret + strlen(&env[caret]) +1 };
}

static inline mach_port_t mach_get_bs_port(char* name) {
  mach_port_name_t task = mach_task_self();

  mach_port_t bs_port;
  if (task_get_special_port(task,
                            TASK_BOOTSTRAP_PORT,
                            &bs_port            ) != KERN_SUCCESS) {
    return 0;
  }

  mach_port_t port;
  if (bootstrap_look_up(bs_port,
                        name,
                        &port   ) != KERN_SUCCESS) {
    return 0;
  }

  return port;
}

static inline void mach_receive_message(mach_port_t port, struct mach_buffer* buffer, bool timeout) {
  *buffer = (struct mach_buffer) { 0 };
  mach_msg_return_t msg_return;
  if (timeout)
    msg_return = mach_msg(&buffer->message.header,
                          MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                          0,
                          sizeof(struct mach_buffer),
                          port,
                          100,
                          MACH_PORT_NULL             );
  else 
    msg_return = mach_msg(&buffer->message.header,
                          MACH_RCV_MSG,
                          0,
                          sizeof(struct mach_buffer),
                          port,
                          MACH_MSG_TIMEOUT_NONE,
                          MACH_PORT_NULL             );

  if (msg_return != MACH_MSG_SUCCESS) {
    buffer->message.descriptor.address = NULL;
  }
}

char* g_rsp = NULL;
static inline char* mach_send_message(mach_port_t port, char* message, uint32_t len) {
  if (!message || !port) {
    return NULL;
  }

  mach_port_t response_port;
  mach_port_name_t task = mach_task_self();
  if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE,
                               &response_port          ) != KERN_SUCCESS) {
    return NULL;
  }

  if (mach_port_insert_right(task, response_port,
                                   response_port,
                                   MACH_MSG_TYPE_MAKE_SEND)!= KERN_SUCCESS) {
    return NULL;
  }

  struct mach_message msg = { 0 };
  msg.header.msgh_remote_port = port;
  msg.header.msgh_local_port = response_port;
  msg.header.msgh_id = response_port;
  msg.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND,
                                            MACH_MSG_TYPE_MAKE_SEND,
                                            0,
                                            MACH_MSGH_BITS_COMPLEX       );

  msg.header.msgh_size = sizeof(struct mach_message);
  msg.msgh_descriptor_count = 1;
  msg.descriptor.address = message;
  msg.descriptor.size = len * sizeof(char);
  msg.descriptor.copy = MACH_MSG_VIRTUAL_COPY;
  msg.descriptor.deallocate = false;
  msg.descriptor.type = MACH_MSG_OOL_DESCRIPTOR;

  mach_msg(&msg.header,
           MACH_SEND_MSG,
           sizeof(struct mach_message),
           0,
           MACH_PORT_NULL,
           MACH_MSG_TIMEOUT_NONE,
           MACH_PORT_NULL              );

  struct mach_buffer buffer = { 0 };
  mach_receive_message(response_port, &buffer, true);

  if (g_rsp) free(g_rsp);
  g_rsp = NULL;
  if (buffer.message.descriptor.address) {
    g_rsp = malloc(strlen(buffer.message.descriptor.address) + 1);
    memcpy(g_rsp, buffer.message.descriptor.address,
                strlen(buffer.message.descriptor.address) + 1);
  } else {
    g_rsp = malloc(1);
    *g_rsp = '\0';
  }

  mach_msg_destroy(&buffer.message.header);

  return g_rsp;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static inline bool mach_server_register(struct mach_server* mach_server, char* bootstrap_name) {
  mach_server->task = mach_task_self();

  if (mach_port_allocate(mach_server->task,
                         MACH_PORT_RIGHT_RECEIVE,
                         &mach_server->port      ) != KERN_SUCCESS) {
    return false;
  }

  if (mach_port_insert_right(mach_server->task,
                             mach_server->port,
                             mach_server->port,
                             MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
    return false;
  }

  if (task_get_special_port(mach_server->task,
                            TASK_BOOTSTRAP_PORT,
                            &mach_server->bs_port) != KERN_SUCCESS) {
    return false;
  }

  if (bootstrap_register(mach_server->bs_port,
                         bootstrap_name,
                         mach_server->port    ) != KERN_SUCCESS) {
    return false;
  }

  return true;
}

static inline bool mach_server_begin(struct mach_server* mach_server, mach_handler handler) {
  mach_server->handler = handler;
  mach_server->is_running = true;
  struct mach_buffer buffer;
  while (mach_server->is_running) {
    mach_receive_message(mach_server->port, &buffer, false);
    mach_server->handler((env)buffer.message.descriptor.address);
    mach_msg_destroy(&buffer.message.header);
  }

  return true;
}
#pragma clang diagnostic pop

static char* g_cmd = NULL;

static inline char* sketchybar(char* message) {
  if (g_cmd && message) {
    g_cmd = realloc(g_cmd, strlen(g_cmd) + strlen(message) + 2);
    if (strlen(g_cmd) > 0) {
      memcpy(g_cmd + strlen(g_cmd) + 1, message, strlen(message) + 1);
      *(g_cmd + strlen(g_cmd)) = ' ';
    }
    else
       memcpy(g_cmd + strlen(g_cmd), message, strlen(message) + 1);

    return NULL;
  } else if (g_cmd && !message) {
    message = g_cmd;
  }

  // printf("%s\n", message);
  uint32_t message_length = strlen(message) + 1;
  char formatted_message[message_length + 1];

  char quote = '\0';
  uint32_t caret = 0;
  for (int i = 0; i < message_length; ++i) {
    if (message[i] == '"' || message[i] == '\'') {
      if (quote == message[i]) quote = '\0';
      else quote = message[i];
      continue;
    }
    formatted_message[caret] = message[i];
    if (message[i] == ' ' && !quote) formatted_message[caret] = '\0';
    caret++;
  }

  if (caret > 0 && formatted_message[caret] == '\0'
      && formatted_message[caret - 1] == '\0') {
    caret--;
  }

  formatted_message[caret] = '\0';
  if (!g_mach_port) g_mach_port = mach_get_bs_port("git.felix.sketchybar");

  return mach_send_message(g_mach_port,
                           formatted_message,
                           caret + 1          );
}

static inline void transaction_create() {
  if (!g_cmd) {
    g_cmd = malloc(1);
    *g_cmd = '\0';
  }
}

static inline char* transaction_commit() {
  char* response = NULL;
  if (g_cmd) {
    response = sketchybar(NULL);
    free(g_cmd);
    g_cmd = NULL;
  }
  return response;
}

static inline void event_server_init(mach_handler event_handler, char* bootstrap_name) {
  mach_server_register(&g_mach_server, bootstrap_name);
}

static inline void event_server_run(mach_handler event_handler) {
  mach_server_begin(&g_mach_server, event_handler);
}
