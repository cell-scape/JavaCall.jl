package org.juliainterop;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

/**
 * InvocationHandler that routes Java interface-method calls to a Julia
 * implementation, identified by a {@code long} handler id, via the native
 * {@link #invokeNative} method (wired up by JavaCall.jl through
 * {@code JNI.RegisterNatives}).
 */
public final class JavaCallInvocationHandler implements InvocationHandler {
    private final long handlerId;

    public JavaCallInvocationHandler(long handlerId) {
        this.handlerId = handlerId;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        String name = method.getName();
        if (args == null) args = new Object[0];
        // Object methods on the proxy itself must not call back into Julia.
        if (name.equals("toString") && args.length == 0) {
            return "JuliaProxy@" + Long.toHexString(handlerId);
        }
        if (name.equals("hashCode") && args.length == 0) {
            return System.identityHashCode(proxy);
        }
        if (name.equals("equals") && args.length == 1) {
            return proxy == args[0];
        }
        Object result = invokeNative(handlerId, name, args);
        if (result instanceof Throwable) {
            throw (Throwable) result;
        }
        return result;
    }

    private static native Object invokeNative(long handlerId, String name, Object[] args);

    /** Build a single-interface proxy in one JNI call from Julia. */
    public static Object newProxy(long handlerId, ClassLoader loader, Class<?> iface) {
        return Proxy.newProxyInstance(loader, new Class<?>[] { iface },
                                      new JavaCallInvocationHandler(handlerId));
    }
}
