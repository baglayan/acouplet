import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;
import org.json.JSONArray;
import org.json.JSONObject;

public final class QueueOracle {
    private final ClassLoader loader;
    private final List<byte[]> writes = new ArrayList<>();
    private final Object decoder;
    private final Object sender;
    private final ReentrantLock lock;
    private final Field waiting;
    private final Field sequence;
    private final Method send;
    private final Method acknowledgment;
    private int closed;

    private Class<?> type(String name) throws Exception {
        return Class.forName(name, true, loader);
    }

    private Object construct(String name, Class<?>[] types, Object... args) throws Exception {
        Constructor<?> constructor = type(name).getDeclaredConstructor(types);
        constructor.setAccessible(true);
        return constructor.newInstance(args);
    }

    private Field field(String name) throws Exception {
        Field field = sender.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field;
    }

    private QueueOracle(ClassLoader loader, int generation) throws Exception {
        this.loader = loader;
        Class<?> transportType = type("lm0.f");
        Object transport = Proxy.newProxyInstance(loader, new Class<?>[]{transportType}, (proxy, method, args) -> {
            switch (method.getName()) {
                case "n0": return 65536;
                case "write":
                    synchronized (writes) {
                        writes.add(((byte[]) args[0]).clone());
                        writes.notifyAll();
                    }
                    return null;
                case "hashCode": return System.identityHashCode(proxy);
                case "equals": return proxy == args[0];
                case "toString": return "QueueOracle transport";
                default: return null;
            }
        });
        decoder = construct(generation == 1 ? "om0.g" : "om0.f",
            new Class<?>[]{type("rm0.a"), type("lm0.k")}, null, null);
        Object writer = construct("qm0.b", new Class<?>[]{transportType}, transport);
        sender = construct("lm0.c", new Class<?>[]{transportType, type("qm0.a"), type("qm0.b"), type("lm0.k")},
            transport, decoder, writer, null);
        Class<?> connectionType = type("lm0.a");
        Object connection = Proxy.newProxyInstance(loader, new Class<?>[]{connectionType}, (proxy, method, args) -> {
            if (method.getName().equals("U0")) closed++;
            return null;
        });
        sender.getClass().getMethod("o", connectionType).invoke(sender, connection);
        lock = (ReentrantLock) field("d").get(sender);
        waiting = field("f");
        sequence = field("b");
        send = sender.getClass().getMethod("n", type("com.sony.songpal.tandemfamily.message.DataType"), byte[].class, long.class, int.class);
        acknowledgment = decoder.getClass().getDeclaredMethod("p", byte.class);
        acknowledgment.setAccessible(true);
    }

    private final class Worker {
        final CountDownLatch finished = new CountDownLatch(1);
        final Thread thread;
        volatile Throwable failure;

        Worker(JSONArray commands, long timeout, int retries) {
            thread = new Thread(() -> {
                try {
                    Class<?> dataType = type("com.sony.songpal.tandemfamily.message.DataType");
                    Method fromByte = dataType.getMethod("fromByteCode", byte.class);
                    for (int index = 0; index < commands.length(); index++) {
                        JSONObject command = commands.getJSONObject(index);
                        JSONArray values = command.getJSONArray("payload");
                        byte[] payload = new byte[values.length()];
                        for (int item = 0; item < values.length(); item++) payload[item] = (byte) values.getInt(item);
                        Object frameType = fromByte.invoke(null, (byte) command.getInt("type"));
                        send.invoke(sender, frameType, payload, timeout, retries);
                    }
                } catch (Throwable exception) {
                    failure = exception instanceof InvocationTargetException ? exception.getCause() : exception;
                } finally {
                    finished.countDown();
                    synchronized (writes) {
                        writes.notifyAll();
                    }
                }
            }, "Sony original ACK sender");
            thread.setDaemon(true);
            thread.start();
        }

        void awaitWrites(int count) throws Exception {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            synchronized (writes) {
                while (writes.size() < count && finished.getCount() != 0) {
                    long remaining = deadline - System.nanoTime();
                    if (remaining <= 0) throw new IllegalStateException("Original sender did not write within 5 seconds");
                    TimeUnit.NANOSECONDS.timedWait(writes, remaining);
                }
                if (writes.size() < count) throw new IllegalStateException("Original sender stopped before expected write", failure);
            }
        }

        void awaitFinished() throws Exception {
            if (!finished.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Original sender did not finish within 5 seconds");
        }
    }

    private JSONObject frame(byte[] encoded) throws Exception {
        byte[] body = (byte[]) type("cp0.b").getMethod("b", byte[].class).invoke(null,
            Arrays.copyOfRange(encoded, 1, encoded.length - 1));
        JSONArray payload = new JSONArray();
        for (int index = 6; index < body.length - 1; index++) payload.put(body[index] & 255);
        return new JSONObject().put("type", body[0] & 255).put("sequence", body[1] & 255).put("payload", payload);
    }

    private JSONArray frames() throws Exception {
        JSONArray result = new JSONArray();
        synchronized (writes) {
            for (byte[] write : writes) result.put(frame(write));
        }
        return result;
    }

    private JSONObject acknowledgments(JSONObject call) throws Exception {
        JSONArray commands = call.getJSONArray("commands");
        JSONArray acknowledgments = call.getJSONArray("acknowledgments");
        if (commands.length() == 0) throw new IllegalArgumentException("An ACK schedule needs at least one command");
        Worker worker = new Worker(commands, 30000, 0);
        int completed = 0;
        try {
            worker.awaitWrites(1);
            JSONArray accepted = new JSONArray();
            for (int index = 0; index < acknowledgments.length(); index++) {
                if (completed == commands.length()) throw new IllegalArgumentException("ACK schedule continues after the last command");
                lock.lock();
                try {
                    if (!waiting.getBoolean(sender)) throw new IllegalStateException("Original sender is not awaiting ACK");
                    acknowledgment.invoke(decoder, (byte) acknowledgments.getInt(index));
                    boolean released = !waiting.getBoolean(sender);
                    accepted.put(released);
                    if (released) completed++;
                } finally {
                    lock.unlock();
                }
                if (completed < commands.length()) worker.awaitWrites(completed + 1);
            }
            if (completed == commands.length()) worker.awaitFinished();
            if (worker.failure != null) throw new IllegalStateException("Original sender failed", worker.failure);
            JSONArray transmitted = frames();
            Object pending = completed == commands.length() ? JSONObject.NULL : transmitted.getJSONObject(completed);
            return new JSONObject().put("transmitted", transmitted).put("accepted", accepted).put("pending", pending);
        } finally {
            while (completed < commands.length() && worker.finished.getCount() != 0) {
                worker.awaitWrites(completed + 1);
                lock.lock();
                try {
                    acknowledgment.invoke(decoder, (byte) (1 - sequence.getByte(sender)));
                    completed++;
                } finally {
                    lock.unlock();
                }
            }
            worker.awaitFinished();
        }
    }

    private JSONObject timeout(JSONObject call) throws Exception {
        JSONArray commands = new JSONArray().put(call.getJSONObject("command"));
        int retries = call.getInt("retries");
        if (retries < 0 || retries > 10) throw new IllegalArgumentException("Retries must be between 0 and 10");
        Worker worker = new Worker(commands, 10, retries);
        worker.awaitFinished();
        if (worker.failure == null) throw new IllegalStateException("Original sender unexpectedly succeeded without ACK");
        JSONArray transmitted = frames();
        boolean identical = true;
        synchronized (writes) {
            for (int index = 1; index < writes.size(); index++) identical &= Arrays.equals(writes.get(0), writes.get(index));
        }
        return new JSONObject().put("transmitted", transmitted).put("identical", identical)
            .put("closed", closed).put("error", worker.failure.getClass().getName());
    }

    public static Object run(ClassLoader loader, JSONObject call) throws Exception {
        int generation = call.getInt("generation");
        if (generation != 1 && generation != 2) throw new IllegalArgumentException("Generation must be 1 or 2");
        QueueOracle oracle = new QueueOracle(loader, generation);
        switch (call.getString("scenario")) {
            case "ack": return oracle.acknowledgments(call);
            case "timeout": return oracle.timeout(call);
            default: throw new IllegalArgumentException("Unknown queue scenario");
        }
    }
}
