#include "config.h"
#include "vm.hpp"
#include "on_stack.hpp"
#include "object_memory.hpp"
#include "call_frame.hpp"
#include "metrics.hpp"

#include "builtin/array.hpp"
#include "builtin/class.hpp"
#include "builtin/module.hpp"
#include "builtin/thread.hpp"
#include "builtin/native_method.hpp"

#include "capi/handle.hpp"

#include "gc/finalize.hpp"

#include "util/logger.hpp"

#include "dtrace/dtrace.h"

namespace rubinius {
  FinalizerHandler::iterator::iterator(FinalizerHandler* fh)
    : handler_(fh)
    , current_list_(NULL)
  {
    if(handler_->live_list_->empty()) {
      if(handler_->lists_->empty()) {
        current_ = handler_->live_list_->begin();
        end_ = handler_->live_list_->end();
        return;
      } else {
        current_list_ = handler_->lists_->front();
      }
    } else {
      current_list_ = handler_->live_list_;
    }

    current_ = current_list_->begin();

    if(handler_->lists_->empty()) {
      end_ = current_list_->end();
    } else {
      lists_iterator_ = handler_->lists_->begin();
      end_ = handler_->lists_->back()->end();
    }
  }

  void FinalizerHandler::iterator::next(bool live) {
    if(current_list_ == handler_->live_list_) {
      if(!live) current_->queued();

      if(++current_ == current_list_->end()) {
        if(!handler_->lists_->empty()) {
          current_list_ = *lists_iterator_;
          current_ = current_list_->begin();
        }
      }
    } else {
      if(++current_ == end_) {
        return;
      } else if(current_ == current_list_->end()) {
        if(++lists_iterator_ != handler_->lists_->end()) {
          current_list_ = *lists_iterator_;
          current_ = current_list_->begin();
        }
      }
    }
  }

  bool FinalizerHandler::iterator::end() {
    return current_ == end_;
  }

  Object* finalizer_handler_trampoline(STATE) {
    state->shared().finalizer_handler()->perform(state);
    GCTokenImpl gct;
    state->gc_dependent(gct, 0);
    return cNil;
  }

  FinalizerHandler::FinalizerHandler(STATE)
    : AuxiliaryThread()
    , shared_(state->shared())
    , thread_(state)
    , lists_(NULL)
    , live_list_(NULL)
    , process_list_(NULL)
    , iterator_(NULL)
    , process_item_kind_(eRuby)
    , thread_exit_(false)
    , finishing_(false)
  {
    shared_.auxiliary_threads()->register_thread(this);
    shared_.set_finalizer_handler(this);

    lists_ = new FinalizeObjectsList();
    live_list_ = new FinalizeObjects();

    initialize(state);
  }

  FinalizerHandler::~FinalizerHandler() {
    shared_.auxiliary_threads()->unregister_thread(this);

    if(iterator_) delete iterator_;
    if(live_list_) delete live_list_;

    if(lists_) {
      for(FinalizeObjectsList::iterator i = lists_->begin(); i != lists_->end(); ++i) {
        delete *i;
      }
      delete lists_;
    }
  }

  void FinalizerHandler::initialize(STATE) {
    live_guard_.init();
    worker_lock_.init();
    worker_cond_.init();
    supervisor_lock_.init();
    supervisor_cond_.init();
    thread_exit_ = false;
    finishing_ = false;
    set_vm(NULL);
    set_thread_running(false);
  }

  void FinalizerHandler::start_thread(STATE) {
    SYNC(state);
    if(vm()) return;
    utilities::thread::Mutex::LockGuard lg(worker_lock_);
    set_vm(state->shared().new_vm());
    vm()->metrics()->init(metrics::eFinalizerMetrics);
    thread_exit_ = false;
    thread_.set(Thread::create(state, vm(), G(thread),
          finalizer_handler_trampoline, true));
    run(state);
  }

  void FinalizerHandler::wakeup(STATE) {
    utilities::thread::Mutex::LockGuard lg(worker_lock_);

    thread_exit_ = true;
    atomic::memory_barrier();

    worker_signal();
  }

  void FinalizerHandler::after_fork_child(STATE) {
    initialize(state);

    start_thread(state);
  }

  void FinalizerHandler::run(STATE) {
    int error = thread_.get()->fork_attached(state);
    if(error) rubinius::bug("Unable to start finalizer handler thread");
  }

  void FinalizerHandler::perform(STATE) {
    GCTokenImpl gct;
    RBX_DTRACE_CHAR_P thread_name =
      const_cast<RBX_DTRACE_CHAR_P>("rbx.finalizer");
    vm()->set_name(thread_name);

    RUBINIUS_THREAD_START(const_cast<RBX_DTRACE_CHAR_P>(thread_name),
                          state->vm()->thread_id(), 1);

    set_thread_running(true);

    state->vm()->thread->hard_unlock(state, gct, 0);
    state->gc_dependent(gct, 0);

    while(!thread_exit_) {
      state->vm()->set_call_frame(0);

      if(!process_list_) first_process_item();

      if(!process_list_) {
        {
          utilities::thread::Mutex::LockGuard lg(worker_lock_);

          // exit_ might have been set after we grabbed the worker_lock
          if(thread_exit_) break;

          state->gc_independent(gct, 0);
          worker_wait();

          if(thread_exit_) break;
        }

        state->gc_dependent(gct, 0);

        {
          utilities::thread::Mutex::LockGuard lg(worker_lock_);
          if(thread_exit_) break;
        }

        continue;
      }

      finalize(state);
      next_process_item();
    }

    set_thread_running(false);

    RUBINIUS_THREAD_STOP(const_cast<RBX_DTRACE_CHAR_P>(thread_name),
                         state->vm()->thread_id(), 1);
  }

  void FinalizerHandler::finalize(STATE) {

    switch(process_item_kind_) {
    case eRuby: {
      if(process_item_->ruby_finalizer) {
        CallFrame* call_frame = 0;
        // Rubinius specific code. If the finalizer is cTrue, then send the
        // object the __finalize__ message.
        if(process_item_->ruby_finalizer->true_p()) {
          process_item_->object->send(state, call_frame, state->symbol("__finalize__"));
        } else {
          Array* ary = Array::create(state, 1);
          ary->set(state, 0, process_item_->object->id(state));
          process_item_->ruby_finalizer->send(state, call_frame, G(sym_call), ary);
        }
      }

      process_item_->status = FinalizeObject::eRubyFinalized;
      break;
    }
    case eNative:
      if(process_item_->finalizer) {

        NativeMethodEnvironment* env = state->vm()->native_method_environment;
        NativeMethodFrame nmf(env, 0, 0);
        CallFrame* call_frame = ALLOCA_CALLFRAME(0);
        call_frame->previous = 0;
        call_frame->constant_scope_ = 0;
        call_frame->dispatch_data = (void*)&nmf;
        call_frame->compiled_code = 0;
        call_frame->flags = CallFrame::cNativeMethod;
        call_frame->optional_jit_data = 0;
        call_frame->top_scope_ = 0;
        call_frame->scope = 0;
        call_frame->arguments = 0;

        env->set_current_call_frame(0);
        env->set_current_native_frame(&nmf);

        // Register the CallFrame, because we might GC below this.
        state->set_call_frame(call_frame);

        nmf.setup(Qnil, Qnil, Qnil, Qnil);

        (*process_item_->finalizer)(state, process_item_->object);

        state->set_call_frame(0);
        env->set_current_call_frame(0);
        env->set_current_native_frame(0);
      }
      process_item_->status = FinalizeObject::eNativeFinalized;
      break;
    case eRelease:
      // Unhook any handle used by fi->object so that we don't accidentally
      // try and mark it later (after we've finalized it)
      if(capi::Handle* handle = process_item_->object->handle(state)) {
        handle->forget_object();
        process_item_->object->clear_handle(state);
      }

      process_item_->status = FinalizeObject::eReleased;

      break;
    }
  }

  void FinalizerHandler::first_process_item() {
    if(!process_list_ && !lists_->empty()) {
      process_list_ = lists_->back();
      process_item_ = process_list_->begin();
    }
  }

  void FinalizerHandler::next_process_item() {
    if(++process_item_ == process_list_->end()) {
      switch(process_item_kind_) {
      case eRuby:
        process_item_ = process_list_->begin();
        process_item_kind_ = eNative;
        break;
      case eNative:
        process_item_ = process_list_->begin();
        process_item_kind_ = eRelease;
        break;
      case eRelease:
        delete process_list_;
        process_list_ = NULL;
        process_item_kind_ = eRuby;
        lists_->pop_back();
        if(vm()) vm()->metrics()->m.finalizer_metrics.objects_finalized++;
        break;
      }
    }
  }

  void FinalizerHandler::finish(STATE, GCToken gct) {
    finishing_ = true;

    stop_thread(state);

    if(process_list_ || !lists_->empty() || !live_list_->empty()) {
      while(true) {
        if(!process_list_) {
          if(live_list_->empty() && lists_->empty()) break;

          // Everything is garbage when halting so keep adding live objects to
          // finalize queue until done.
          if(!live_list_->empty()) {
            for(FinalizeObjects::iterator i = live_list_->begin();
                i != live_list_->end();
                ++i)
            {
              i->queued();
            }

            queue_objects();
          }

          first_process_item();
          if(!process_list_) break;
        }

        while(process_list_) {
          finalize(state);
          next_process_item();
        }
      }
    }

    if(!lists_->empty() || !live_list_->empty() || process_list_ != NULL) {
      utilities::logger::warn("FinalizerHandler exiting with pending finalizers");
    }
  }

  void FinalizerHandler::record(Object* obj, FinalizerFunction func) {
    utilities::thread::Mutex::LockGuard lg(live_guard_);

    if(finishing_) return;

    FinalizeObject fi;
    fi.object = obj;
    fi.status = FinalizeObject::eLive;
    fi.finalizer = func;

    // Makes a copy of fi.
    live_list_->push_front(fi);

    vm()->metrics()->m.finalizer_metrics.objects_queued++;
  }

  void FinalizerHandler::set_ruby_finalizer(Object* obj, Object* finalizer) {
    utilities::thread::Mutex::LockGuard lg(live_guard_);

    // Ignore Ruby finalizers created when finishing running finalizers.
    if(finishing_) return;

    // Check if the object is already in the finalizer list.
    for(FinalizeObjects::iterator i = live_list_->begin();
        i != live_list_->end();
        ++i)
    {
      if(i->object == obj) {
        if(finalizer->nil_p()) {
          live_list_->erase(i);
        } else {
          i->ruby_finalizer = finalizer;
        }
        return;
      }
    }

    // Adding a nil finalizer is only used to delete an existing finalizer,
    // which we apparently don't have if we get here.
    if(finalizer->nil_p()) {
      return;
    }

    // Ok, create it.

    FinalizeObject fi;
    fi.object = obj;
    fi.status = FinalizeObject::eLive;

    // Rubinius specific API. If the finalizer is the object, we're going to send
    // the object __finalize__. We mark that the user wants this by putting cTrue
    // as the ruby_finalizer.
    if(obj == finalizer) {
      fi.ruby_finalizer = cTrue;
    } else {
      fi.ruby_finalizer = finalizer;
    }

    // Makes a copy of fi.
    live_list_->push_front(fi);
  }

  void FinalizerHandler::queue_objects() {
    FinalizeObjects* dead_list = new FinalizeObjects();

    for(FinalizeObjects::iterator i = live_list_->begin();
        i != live_list_->end();
        /* advance is handled in the loop */)
    {
      if(i->queued_p()) {
        dead_list->push_front(*i);
        i = live_list_->erase(i);
      } else {
        ++i;
      }
    }

    if(!dead_list->empty()) {
      lists_->push_front(dead_list);
    } else {
      delete dead_list;
    }
  }

  void FinalizerHandler::start_collection(STATE) {
    if(process_item_kind_ == eRelease) {
      while(process_list_) {
        finalize(state);
        next_process_item();
      }
    }
  }

  void FinalizerHandler::finish_collection(STATE) {
    queue_objects();

    if(iterator_) {
      delete iterator_;
      iterator_ = NULL;
    }

    worker_signal();
  }

  void FinalizerHandler::supervisor_signal() {
    supervisor_cond_.signal();
  }

  void FinalizerHandler::supervisor_wait() {
    supervisor_cond_.wait(supervisor_lock_);
  }

  void FinalizerHandler::worker_signal() {
    worker_cond_.signal();
  }

  void FinalizerHandler::worker_wait() {
    worker_cond_.wait(worker_lock_);
  }

  FinalizerHandler::iterator& FinalizerHandler::begin() {
    if(iterator_) delete iterator_;
    iterator_ = new iterator(this);
    return *iterator_;
  }
}
