import android.os.Build;
import dalvik.system.DexClassLoader;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Array;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

public final class OracleRunner {
    private final ClassLoader loader;
    private final Map<String, Object> objects = new HashMap<>();

    private OracleRunner(String apkPath) {
        loader = new DexClassLoader(apkPath, null, null, OracleRunner.class.getClassLoader());
    }

    private Class<?> type(String name) throws ClassNotFoundException {
        switch (name) {
            case "boolean": return boolean.class;
            case "byte": return byte.class;
            case "short": return short.class;
            case "int": return int.class;
            case "long": return long.class;
            case "float": return float.class;
            case "double": return double.class;
            case "char": return char.class;
            default:
                if (name.endsWith("[]")) {
                    return Array.newInstance(type(name.substring(0, name.length() - 2)), 0).getClass();
                }
                return Class.forName(name, true, loader);
        }
    }

    private Object reference(String id) {
        if (!objects.containsKey(id)) {
            throw new IllegalArgumentException("No successful result named " + id);
        }
        return objects.get(id);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private Object argument(Object value, Class<?> expected) throws Exception {
        if (value == JSONObject.NULL) {
            return null;
        }
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            if (object.has("ref")) {
                return reference(object.getString("ref"));
            }
            if (object.has("bytes")) {
                String hex = object.getString("bytes");
                if (hex.length() % 2 != 0) {
                    throw new IllegalArgumentException("Byte hex must have an even length");
                }
                byte[] bytes = new byte[hex.length() / 2];
                for (int index = 0; index < bytes.length; index++) {
                    bytes[index] = (byte) Integer.parseInt(hex.substring(index * 2, index * 2 + 2), 16);
                }
                return bytes;
            }
            if (object.has("enum")) {
                return Enum.valueOf((Class<? extends Enum>) type(object.getString("enum")), object.getString("name"));
            }
            throw new IllegalArgumentException("Argument object requires ref, bytes, or enum");
        }
        if (value instanceof JSONArray) {
            JSONArray input = (JSONArray) value;
            if (expected.isArray()) {
                Class<?> component = expected.getComponentType();
                Object array = Array.newInstance(component, input.length());
                for (int index = 0; index < input.length(); index++) {
                    Array.set(array, index, argument(input.get(index), component));
                }
                return array;
            }
            List<Object> list = new ArrayList<>();
            for (int index = 0; index < input.length(); index++) {
                list.add(argument(input.get(index), Object.class));
            }
            return list;
        }
        if (value instanceof Number) {
            Number number = (Number) value;
            if (expected == byte.class || expected == Byte.class) return number.byteValue();
            if (expected == short.class || expected == Short.class) return number.shortValue();
            if (expected == int.class || expected == Integer.class) return number.intValue();
            if (expected == long.class || expected == Long.class) return number.longValue();
            if (expected == float.class || expected == Float.class) return number.floatValue();
            if (expected == double.class || expected == Double.class) return number.doubleValue();
        }
        if (expected == char.class || expected == Character.class) {
            String string = (String) value;
            if (string.length() != 1) throw new IllegalArgumentException("Expected one character");
            return string.charAt(0);
        }
        return value;
    }

    private Object invoke(JSONObject call) throws Exception {
        if (call.has("op")) {
            if (call.getString("op").equals("queue")) return QueueOracle.run(loader, call);
            if (call.getString("op").equals("get_reply")) return GetReplyOracle.run(loader, call);
            return frame(call);
        }
        Object target = call.has("target") ? reference(call.getString("target")) : null;
        Class<?> owner = call.has("class") ? type(call.getString("class")) : target.getClass();
        if (call.has("field")) {
            Field field = owner.getDeclaredField(call.getString("field"));
            field.setAccessible(true);
            return field.get(target);
        }
        JSONArray typeNames = call.optJSONArray("types");
        JSONArray values = call.optJSONArray("args");
        int count = typeNames == null ? 0 : typeNames.length();
        if ((values == null ? 0 : values.length()) != count) {
            throw new IllegalArgumentException("types and args must have equal lengths");
        }
        Class<?>[] types = new Class<?>[count];
        Object[] arguments = new Object[count];
        for (int index = 0; index < count; index++) {
            types[index] = type(typeNames.getString(index));
            arguments[index] = argument(values.get(index), types[index]);
        }
        String name = call.getString("method");
        if (name.equals("<init>")) {
            Constructor<?> constructor = owner.getDeclaredConstructor(types);
            constructor.setAccessible(true);
            return constructor.newInstance(arguments);
        }
        Method method;
        try {
            method = owner.getDeclaredMethod(name, types);
        } catch (NoSuchMethodException exception) {
            method = owner.getMethod(name, types);
        }
        method.setAccessible(true);
        return method.invoke(target, arguments);
    }

    private byte[] frame(JSONObject call) throws Exception {
        int mtu = call.optInt("mtu", 65536);
        if (mtu <= 0) throw new IllegalArgumentException("MTU must be positive");
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Class<?> transportType = type("lm0.f");
        Object transport = Proxy.newProxyInstance(loader, new Class<?>[] {transportType}, (proxy, method, arguments) -> {
            if (method.getName().equals("n0")) return mtu;
            if (method.getName().equals("write")) {
                output.write((byte[]) arguments[0]);
                return null;
            }
            throw new UnsupportedOperationException("Unexpected transport call " + method.getName());
        });
        Class<?> encoderType = type("qm0.b");
        Object encoder = encoderType.getConstructor(transportType).newInstance(transport);
        byte sequence = (byte) call.getInt("sequence");
        String operation = call.getString("op");
        if (operation.equals("ack")) {
            encoderType.getMethod("d", byte.class).invoke(encoder, sequence);
        } else if (operation.equals("frame")) {
            byte dataType = (byte) call.getInt("type");
            byte[] payload = (byte[]) argument(new JSONObject().put("bytes", call.getString("payload")), byte[].class);
            encoderType.getMethod("e", byte.class, byte[].class, byte.class).invoke(encoder, dataType, payload, sequence);
        } else {
            throw new IllegalArgumentException("Unknown operation " + operation);
        }
        return output.toByteArray();
    }

    private Object result(Object value) throws Exception {
        if (value == null) return JSONObject.NULL;
        if (value instanceof JSONObject || value instanceof JSONArray) return value;
        if (value instanceof byte[]) {
            StringBuilder hex = new StringBuilder();
            for (byte item : (byte[]) value) {
                hex.append(Character.forDigit((item & 255) >>> 4, 16));
                hex.append(Character.forDigit(item & 15, 16));
            }
            return new JSONObject().put("bytes", hex.toString());
        }
        if (value instanceof Enum<?>) {
            Enum<?> item = (Enum<?>) value;
            return new JSONObject().put("enum", item.getDeclaringClass().getName()).put("name", item.name());
        }
        if (value.getClass().isArray()) {
            JSONArray array = new JSONArray();
            for (int index = 0; index < Array.getLength(value); index++) array.put(result(Array.get(value, index)));
            return array;
        }
        if (value instanceof Iterable<?>) {
            JSONArray array = new JSONArray();
            for (Object item : (Iterable<?>) value) array.put(result(item));
            return array;
        }
        if (value instanceof Number || value instanceof String || value instanceof Boolean) return value;
        if (value instanceof Character) return value.toString();
        return new JSONObject().put("class", value.getClass().getName());
    }

    private JSONObject run(JSONArray calls) throws Exception {
        JSONArray results = new JSONArray();
        for (int index = 0; index < calls.length(); index++) {
            JSONObject call = calls.getJSONObject(index);
            String id = call.getString("id");
            JSONObject output = new JSONObject().put("id", id);
            try {
                Object value = invoke(call);
                Object encoded = result(value);
                objects.put(id, value);
                output.put("ok", true).put("value", encoded);
            } catch (Throwable exception) {
                if (exception instanceof InvocationTargetException) exception = exception.getCause();
                output.put("ok", false).put("error", new JSONObject()
                    .put("type", exception.getClass().getName())
                    .put("message", exception.getMessage() == null ? JSONObject.NULL : exception.getMessage()));
            }
            results.put(output);
        }
        return new JSONObject().put("results", results)
            .put("vm_name", System.getProperty("java.vm.name"))
            .put("vm_version", System.getProperty("java.vm.version"))
            .put("android_api", Build.VERSION.SDK_INT)
            .put("class_loader", loader.getClass().getName());
    }

    public static void main(String[] args) throws Exception {
        String input = new String(Files.readAllBytes(Paths.get(args[1])), StandardCharsets.UTF_8);
        JSONObject request = new JSONObject(input);
        JSONObject output = new OracleRunner(args[0]).run(request.getJSONArray("calls"));
        System.out.println("SONY_APK_ORACLE_RESULT=" + output.toString());
    }
}
