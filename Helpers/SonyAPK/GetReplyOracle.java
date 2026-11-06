import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;
import java.util.concurrent.locks.ReentrantLock;
import org.json.JSONArray;
import org.json.JSONObject;

public final class GetReplyOracle {
    private final ClassLoader loader;
    private final int generation;
    private final long started = System.nanoTime();
    private final List<JSONObject> events = new ArrayList<>();
    private final List<String> diagnostics = new ArrayList<>();
    private final List<JSONObject> requests = new ArrayList<>();
    private final CountDownLatch firstWrite = new CountDownLatch(1);
    private final CountDownLatch finished = new CountDownLatch(1);
    private final Object connection;
    private final Object sender;
    private final Object wrapper;
    private final ReentrantLock lock;
    private final Field waiting;
    private final Field sequence;
    private final List<?> listeners;
    private final Method acknowledgment;
    private final Method receive;
    private final Object dataType;
    private final Method query;
    private Object decoder;
    private CountDownLatch reply;
    private Thread worker;
    private volatile Object returned;
    private volatile Throwable failure;
    private volatile long completed;
    private long ackTime;
    private long interruptTime;
    private byte incomingSequence;
    private int connectionClosed;
    private int transportClosed;

    private Class<?> type(String name) throws Exception {
        return Class.forName(name, true, loader);
    }

    private Field field(Object target, String name) throws Exception {
        Field field = target.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field;
    }

    private Object proxy(String name, InvocationHandler handler) throws Exception {
        return Proxy.newProxyInstance(loader, new Class<?>[]{type(name)}, (value, method, args) -> {
            switch (method.getName()) {
                case "hashCode": return System.identityHashCode(value);
                case "equals": return value == args[0];
                case "toString": return "GetReplyOracle " + name;
                default: return handler.invoke(value, method, args);
            }
        });
    }

    private void record(String name, JSONObject detail) throws Exception {
        detail.put("event", name).put("elapsed_ns", System.nanoTime() - started);
        synchronized (events) {
            events.add(detail);
        }
    }

    private JSONObject frame(byte[] encoded) throws Exception {
        byte[] body = (byte[]) type("cp0.b").getMethod("b", byte[].class).invoke(null,
            Arrays.copyOfRange(encoded, 1, encoded.length - 1));
        JSONArray payload = new JSONArray();
        for (int index = 6; index < body.length - 1; index++) payload.put(body[index] & 255);
        return new JSONObject().put("type", body[0] & 255).put("sequence", body[1] & 255).put("payload", payload);
    }

    private GetReplyOracle(ClassLoader loader, int generation) throws Exception {
        this.loader = loader;
        this.generation = generation;
        Object transport = proxy("lm0.f", (value, method, args) -> {
            switch (method.getName()) {
                case "n0": return 65536;
                case "p1": decoder = args[0]; return null;
                case "write":
                    JSONObject frame = frame(((byte[]) args[0]).clone());
                    record("write", new JSONObject().put("frame", frame));
                    if (frame.getInt("type") != 1) {
                        synchronized (requests) {
                            requests.add(frame);
                        }
                        firstWrite.countDown();
                    }
                    return null;
                case "close": transportClosed++; break;
                case "start":
                case "j1":
                case "V0": break;
                default: throw new UnsupportedOperationException("Unexpected transport method: " + method.getName());
            }
            record("transport_" + method.getName(), new JSONObject());
            return null;
        });
        Object lifecycle = proxy("lm0.g", (value, method, args) -> {
            if (method.getName().equals("e")) connectionClosed++;
            else if (!method.getName().equals("c")) throw new UnsupportedOperationException(method.getName());
            record("connection_" + method.getName(), new JSONObject());
            return null;
        });
        Object scheduler = proxy("com.sony.songpal.util.t", (value, method, args) -> {
            if (method.getName().equals("a")) return false;
            if (!method.getName().equals("f")) throw new UnsupportedOperationException("Unexpected scheduler method: " + method.getName());
            if (Thread.currentThread() != worker) throw new IllegalStateException("Original send did not run on the probe worker");
            record("worker_assertion", new JSONObject());
            return null;
        });
        Object diagnostic = proxy("com.sony.songpal.mdr.j2objc.tandem.a", (value, method, args) -> {
            if (!method.getName().equals("a")) throw new UnsupportedOperationException(method.getName());
            synchronized (diagnostics) {
                diagnostics.add((String) args[0]);
            }
            record("diagnostic", new JSONObject().put("message", args[0]));
            return null;
        });
        Class<?> tableType = type("com.sony.songpal.tandemfamily.mdr.CommandTableSet");
        Object table = tableType.getField("TABLE_SET_" + generation).get(null);
        Class<?> connectionType = type("om0.e");
        connection = connectionType.getConstructor(tableType, type("lm0.f"), String.class, type("lm0.g"), type("com.sony.songpal.util.t"))
            .newInstance(table, transport, "Original GET lifecycle", lifecycle, scheduler);
        sender = field(connection, "a").get(connection);
        listeners = (List<?>) field(connection, "e").get(connection);
        lock = (ReentrantLock) field(sender, "d").get(sender);
        waiting = field(sender, "f");
        sequence = field(sender, "b");
        acknowledgment = decoder.getClass().getDeclaredMethod("p", byte.class);
        acknowledgment.setAccessible(true);
        Class<?> dataTypeClass = type("com.sony.songpal.tandemfamily.message.DataType");
        dataType = dataTypeClass.getField("DATA_MDR").get(null);
        receive = decoder.getClass().getDeclaredMethod("i", dataTypeClass, byte.class, byte[].class);
        receive.setAccessible(true);
        Class<?> wrapperType = type(generation == 1 ? "k70.v0" : "l70.m1");
        wrapper = wrapperType.getMethod(generation == 1 ? "V0" : "J2", connectionType, type("com.sony.songpal.mdr.j2objc.tandem.a"))
            .invoke(null, connection, diagnostic);
        query = wrapperType.getMethod(generation == 1 ? "b0" : "E0");
        connectionType.getMethod("start").invoke(connection);
    }

    private void start() throws Exception {
        worker = new Thread(() -> {
            try {
                returned = query.invoke(wrapper);
                record("wrapper_returned", new JSONObject().put("is_null", returned == null));
            } catch (Throwable error) {
                failure = error instanceof InvocationTargetException ? error.getCause() : error;
            } finally {
                completed = System.nanoTime();
                finished.countDown();
            }
        }, "Sony original GET wrapper");
        worker.setDaemon(true);
        worker.start();
        if (!firstWrite.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Original wrapper did not send within watchdog: " + failure, failure);
        if (!lock.tryLock(5, TimeUnit.SECONDS)) throw new IllegalStateException("Original sender lock did not become available");
        try {
            if (!waiting.getBoolean(sender)) throw new IllegalStateException("Original sender is not awaiting its ACK");
            synchronized (listeners) {
                for (Object reference : listeners) {
                    Object handler = ((WeakReference<?>) reference).get();
                    if (handler != null && handler.getClass().getName().equals(wrapper.getClass().getName() + "$a")) {
                        if (reply != null) throw new IllegalStateException("Multiple original wrapper listeners");
                        reply = (CountDownLatch) field(handler, "d").get(handler);
                    }
                }
            }
            if (reply == null) throw new IllegalStateException("Original wrapper reply latch was not registered before send");
        } finally {
            lock.unlock();
        }
    }

    private JSONObject snapshot() throws Exception {
        if (!lock.tryLock(5, TimeUnit.SECONDS)) throw new IllegalStateException("Original sender lock did not become available");
        try {
            int count = 0;
            synchronized (listeners) {
                for (Object reference : listeners) if (((WeakReference<?>) reference).get() != null) count++;
            }
            return new JSONObject().put("awaiting_ack", waiting.getBoolean(sender)).put("reply_remaining", reply.getCount())
                .put("listener_count", count).put("worker_finished", finished.getCount() == 0);
        } finally {
            lock.unlock();
        }
    }

    private void ack() throws Exception {
        if (!lock.tryLock(5, TimeUnit.SECONDS)) throw new IllegalStateException("Original sender lock did not become available");
        try {
            byte value = (byte) (1 - sequence.getByte(sender));
            ackTime = System.nanoTime();
            record("input_ack", new JSONObject().put("sequence", value));
            acknowledgment.invoke(decoder, value);
        } finally {
            lock.unlock();
        }
    }

    private void reply(boolean unrelated, boolean late) throws Exception {
        byte[] payload = generation == 1
            ? new byte[]{(byte) 0xE7, (byte) (unrelated ? 2 : 1), 0, 1}
            : new byte[]{(byte) 0xE7, (byte) (unrelated ? 5 : 0), 1};
        JSONArray bytes = new JSONArray();
        for (byte value : payload) bytes.put(value & 255);
        record("input_reply", new JSONObject().put("payload", bytes).put("sequence", incomingSequence)
            .put("unrelated", unrelated).put("late", late));
        receive.invoke(decoder, dataType, incomingSequence, payload);
        incomingSequence = (byte) (1 - incomingSequence);
    }

    private void awaitReplyWait() throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (finished.getCount() != 0 && System.nanoTime() < deadline) {
            StackTraceElement[] stack = worker.getStackTrace();
            boolean latchWait = false;
            boolean wrapperWait = false;
            boolean senderWait = false;
            for (StackTraceElement item : stack) {
                latchWait |= item.getClassName().equals("java.util.concurrent.CountDownLatch") && item.getMethodName().equals("await");
                wrapperWait |= item.getClassName().equals(wrapper.getClass().getName())
                    && item.getMethodName().equals(generation == 1 ? "W0" : "K2");
                senderWait |= item.getClassName().equals("lm0.c") && item.getMethodName().equals("n");
            }
            if (latchWait && wrapperWait && !senderWait) {
                JSONArray observed = new JSONArray();
                for (StackTraceElement item : stack) observed.put(item.toString());
                record("reply_wait_observed", new JSONObject().put("stack", observed));
                return;
            }
            LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(1));
        }
        throw new IllegalStateException("Original wrapper reply wait was not observed before completion/watchdog: " + failure, failure);
    }

    private void interrupt() throws Exception {
        interruptTime = System.nanoTime();
        record("interrupt", new JSONObject());
        worker.interrupt();
    }

    private void awaitFinished() throws Exception {
        if (!finished.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Original wrapper did not finish within watchdog");
        if (failure != null) throw new IllegalStateException("Original wrapper failed: " + failure, failure);
    }

    private JSONObject scenario(String scenario) throws Exception {
        start();
        JSONObject snapshots = new JSONObject().put("initial", snapshot());
        switch (scenario) {
            case "reply_before_ack":
                reply(false, false);
                snapshots.put("before_ack", snapshot());
                ack();
                break;
            case "ack_before_reply":
                ack();
                snapshots.put("before_reply", snapshot());
                reply(false, false);
                break;
            case "withheld_reply":
                ack();
                snapshots.put("before_reply", snapshot());
                break;
            case "unrelated_reply":
                ack();
                reply(true, false);
                snapshots.put("after_unrelated", snapshot());
                reply(false, false);
                break;
            case "cancel_reply_wait":
                ack();
                awaitReplyWait();
                snapshots.put("before_interrupt", snapshot());
                interrupt();
                break;
            case "cancel_ack_wait":
                interrupt();
                break;
            default: throw new IllegalArgumentException("Unknown GET lifecycle scenario: " + scenario);
        }
        awaitFinished();
        snapshots.put("finished", snapshot());
        if (scenario.equals("withheld_reply") || scenario.equals("cancel_reply_wait")) {
            reply(false, true);
            snapshots.put("after_late_reply", snapshot());
        }
        Object value = JSONObject.NULL;
        if (returned != null) {
            Object mode = returned.getClass().getMethod(generation == 1 ? "f" : "e").invoke(returned);
            value = ((Byte) mode.getClass().getMethod("byteCode").invoke(mode)) & 255;
        }
        JSONObject output = new JSONObject().put("generation", generation).put("scenario", scenario)
            .put("wrapper", wrapper.getClass().getName()).put("method", query.getName()).put("return_value", value)
            .put("snapshots", snapshots).put("connection_closed", connectionClosed).put("transport_closed", transportClosed)
            .put("elapsed_after_ack_ns", ackTime == 0 ? JSONObject.NULL : completed - ackTime)
            .put("elapsed_after_interrupt_ns", interruptTime == 0 ? JSONObject.NULL : completed - interruptTime);
        synchronized (events) { output.put("events", new JSONArray(events)); }
        synchronized (requests) { output.put("requests", new JSONArray(requests)); }
        synchronized (diagnostics) { output.put("diagnostics", new JSONArray(diagnostics)); }
        return output;
    }

    private void close() throws Exception {
        if (worker != null && finished.getCount() != 0) worker.interrupt();
        if (!lock.tryLock(5, TimeUnit.SECONDS)) throw new IllegalStateException("Could not acquire original sender lock during cleanup");
        try {
            if (waiting.getBoolean(sender)) acknowledgment.invoke(decoder, (byte) (1 - sequence.getByte(sender)));
        } finally {
            lock.unlock();
        }
        if (worker != null && !finished.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Probe worker remained active after cleanup");
        connection.getClass().getMethod("g").invoke(connection);
    }

    public static Object run(ClassLoader loader, JSONObject call) throws Exception {
        int generation = call.getInt("generation");
        if (generation != 1 && generation != 2) throw new IllegalArgumentException("Generation must be 1 or 2");
        String scenario = call.getString("scenario");
        if (!Arrays.asList("reply_before_ack", "ack_before_reply", "withheld_reply", "unrelated_reply", "cancel_reply_wait", "cancel_ack_wait").contains(scenario)) {
            throw new IllegalArgumentException("Unknown GET lifecycle scenario: " + scenario);
        }
        GetReplyOracle oracle = new GetReplyOracle(loader, generation);
        try {
            return oracle.scenario(scenario);
        } finally {
            oracle.close();
        }
    }
}
