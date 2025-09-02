/**
 * @brief Modern C++ wrapper for the Etch scripting language
 *
 * This header provides a modern C++ interface wrapping the Etch C API.
 * It uses RAII for automatic resource management and provides a more
 * idiomatic C++ interface with exceptions, std::string, and std::function.
 *
 * Example usage:
 * @code
 *   try {
 *     etch::Context ctx;
 *     ctx.compileString("fn main(): int { print(\"Hello!\"); return 0 }");
 *     ctx.execute();
 *   } catch (const etch::Exception& e) {
 *     std::cerr << "Error: " << e.what() << std::endl;
 *   }
 * @endcode
 */

#ifndef ETCH_HPP
#define ETCH_HPP

#include <etch.h>

#include <cstdlib>
#include <cstdio>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <utility>
#include <vector>

#if !defined(ETCH_CPP_EXCEPTIONS)
#  if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
#    define ETCH_CPP_EXCEPTIONS 1
#  else
#    define ETCH_CPP_EXCEPTIONS 0
#  endif
#endif

namespace etch {

class Context;
class ContextView;

/** Exception thrown for Etch API failures */
class Exception : public std::runtime_error {
public:
    explicit Exception(const std::string& msg)
        : std::runtime_error(msg) {}
};

namespace detail {

inline constexpr bool kCppExceptionsEnabled = ETCH_CPP_EXCEPTIONS == 1;

[[noreturn]] inline void throwOrAbort(std::string message) {
#if ETCH_CPP_EXCEPTIONS
    throw Exception(std::move(message));
#else
    std::fputs("etch fatal: ", stderr);
    if (message.empty()) {
        std::fputs("Etch API failure", stderr);
    } else {
        std::fputs(message.c_str(), stderr);
    }
    std::fputc('\n', stderr);
    std::abort();
#endif
}

[[noreturn]] inline void throwOrAbort(const char* message) {
    if (message) {
        throwOrAbort(std::string(message));
    } else {
        throwOrAbort(std::string("Etch API failure"));
    }
}

} // namespace detail

/** RAII wrapper for EtchValue */
class Value {
public:
    enum class Ownership { Acquire, Borrow };

    Value()
        : handle_(ensureHandle(etch_value_new_nil(), "Failed to create nil value")), owns_(true) {}

    explicit Value(int64_t v)
        : handle_(ensureHandle(etch_value_new_int(v), "Failed to create int value")), owns_(true) {}

    explicit Value(double v)
        : handle_(ensureHandle(etch_value_new_float(v), "Failed to create float value")), owns_(true) {}

    explicit Value(bool v)
        : handle_(ensureHandle(etch_value_new_bool(v ? 1 : 0), "Failed to create bool value")), owns_(true) {}

    explicit Value(const std::string& v)
        : handle_(ensureHandle(etch_value_new_string(v.c_str()), "Failed to create string value")), owns_(true) {}

    explicit Value(std::string_view v)
        : Value(std::string(v)) {}

    explicit Value(const char* v)
        : handle_(ensureHandle(etch_value_new_string(v), "Failed to create string value")), owns_(true) {}

    explicit Value(char v)
        : handle_(ensureHandle(etch_value_new_char(v), "Failed to create char value")), owns_(true) {}

    explicit Value(EtchValue v, Ownership ownership = Ownership::Acquire)
        : handle_(v), owns_(ownership == Ownership::Acquire) {}

    ~Value() { reset(); }

    Value(Value&& other) noexcept
        : handle_(other.handle_), owns_(other.owns_) {
        other.handle_ = nullptr;
        other.owns_ = false;
    }

    Value& operator=(Value&& other) noexcept {
        if (this != &other) {
            reset();
            handle_ = other.handle_;
            owns_ = other.owns_;
            other.handle_ = nullptr;
            other.owns_ = false;
        }
        return *this;
    }

    Value(const Value&) = delete;
    Value& operator=(const Value&) = delete;

    bool isInt() const { return handle_ && etch_value_is_int(handle_); }
    bool isFloat() const { return handle_ && etch_value_is_float(handle_); }
    bool isBool() const { return handle_ && etch_value_is_bool(handle_); }
    bool isString() const { return handle_ && etch_value_is_string(handle_); }
    bool isNil() const { return handle_ == nullptr || etch_value_is_nil(handle_); }
    bool isArray() const { return handle_ && etch_value_is_array(handle_); }
    bool isSome() const { return handle_ && etch_value_is_some(handle_); }
    bool isNone() const { return handle_ && etch_value_is_none(handle_); }
    bool isOk() const { return handle_ && etch_value_is_ok(handle_); }
    bool isErr() const { return handle_ && etch_value_is_err(handle_); }

    EtchValueType getType() const {
        if (!handle_) {
            return ETCH_TYPE_NIL;
        }
        int type = etch_value_get_type(handle_);
        if (type < 0) {
            detail::throwOrAbort("Unable to query value type");
        }
        return static_cast<EtchValueType>(type);
    }

    int64_t toInt() const {
        int64_t result = 0;
        if (!handle_ || etch_value_to_int(handle_, &result) != 0) {
            detail::throwOrAbort("Value is not an int");
        }
        return result;
    }

    double toFloat() const {
        double result = 0.0;
        if (!handle_ || etch_value_to_float(handle_, &result) != 0) {
            detail::throwOrAbort("Value is not a float");
        }
        return result;
    }

    bool toBool() const {
        int result = 0;
        if (!handle_ || etch_value_to_bool(handle_, &result) != 0) {
            detail::throwOrAbort("Value is not a bool");
        }
        return result != 0;
    }

    std::string toString() const {
        const char* str = handle_ ? etch_value_to_string(handle_) : nullptr;
        if (!str) {
            detail::throwOrAbort("Value is not a string");
        }
        return std::string(str);
    }

    std::string_view toStringView() const {
        const char* str = handle_ ? etch_value_to_string(handle_) : nullptr;
        if (!str) {
            detail::throwOrAbort("Value is not a string");
        }
        return std::string_view(str);
    }

    char toChar() const {
        char result = 0;
        if (!handle_ || etch_value_to_char(handle_, &result) != 0) {
            detail::throwOrAbort("Value is not a char");
        }
        return result;
    }

    size_t arrayLength() const {
        if (!isArray()) {
            detail::throwOrAbort("Value is not an array");
        }
        const int len = etch_value_array_length(handle_);
        if (len < 0) {
            detail::throwOrAbort("Failed to query array length");
        }
        return static_cast<size_t>(len);
    }

    Value arrayGet(size_t index) const {
        if (!isArray()) {
            detail::throwOrAbort("Value is not an array");
        }
        EtchValue elem = etch_value_array_get(handle_, static_cast<int>(index));
        if (!elem) {
            detail::throwOrAbort("Failed to read array element");
        }
        return Value(elem);
    }

    void arraySet(size_t index, const Value& value) {
        if (!isArray() || etch_value_array_set(handle_, static_cast<int>(index), value.handle_) != 0) {
            detail::throwOrAbort("Failed to set array element");
        }
    }

    void arrayPush(const Value& value) {
        if (!isArray() || etch_value_array_push(handle_, value.handle_) != 0) {
            detail::throwOrAbort("Failed to append array element");
        }
    }

    std::vector<Value> toArray() const {
        std::vector<Value> result;
        const size_t len = arrayLength();
        result.reserve(len);
        for (size_t i = 0; i < len; ++i) {
            result.emplace_back(arrayGet(i));
        }
        return result;
    }

    Value unwrapOption() const {
        if (!isSome()) {
            detail::throwOrAbort("Option does not contain a value");
        }
        EtchValue inner = etch_value_option_unwrap(handle_);
        if (!inner) {
            detail::throwOrAbort("Failed to unwrap option value");
        }
        return Value(inner);
    }

    Value unwrapOk() const {
        if (!isOk()) {
            detail::throwOrAbort("Result is not ok");
        }
        EtchValue inner = etch_value_result_unwrap_ok(handle_);
        if (!inner) {
            detail::throwOrAbort("Failed to unwrap ok value");
        }
        return Value(inner);
    }

    Value unwrapErr() const {
        if (!isErr()) {
            detail::throwOrAbort("Result is not err");
        }
        EtchValue inner = etch_value_result_unwrap_err(handle_);
        if (!inner) {
            detail::throwOrAbort("Failed to unwrap err value");
        }
        return Value(inner);
    }

    static Value array(std::span<const Value> elements) {
        std::vector<EtchValue> raw;
        raw.reserve(elements.size());
        for (const auto& elem : elements) {
            raw.push_back(elem.handle_);
        }
        EtchValue arr = etch_value_new_array(raw.empty() ? nullptr : raw.data(), static_cast<int>(raw.size()));
        return Value(ensureHandle(arr, "Failed to create array"));
    }

    static Value some(const Value& value) {
        return Value(ensureHandle(etch_value_new_some(value.handle_), "Failed to create option some"));
    }

    static Value none() {
        return Value(ensureHandle(etch_value_new_none(), "Failed to create option none"));
    }

    static Value ok(const Value& value) {
        return Value(ensureHandle(etch_value_new_ok(value.handle_), "Failed to create result ok"));
    }

    static Value err(const Value& value) {
        return Value(ensureHandle(etch_value_new_err(value.handle_), "Failed to create result err"));
    }

    Value clone() const {
        if (!handle_) {
            return Value();
        }
        return Value(ensureHandle(etch_value_clone(handle_), "Failed to clone value"));
    }

    EtchValue handle() const { return handle_; }

    EtchValue release() {
        owns_ = false;
        EtchValue tmp = handle_;
        handle_ = nullptr;
        return tmp;
    }

    static Value borrow(EtchValue raw) {
        return Value(raw, Ownership::Borrow);
    }

private:
    static EtchValue ensureHandle(EtchValue handle, const char* message) {
        if (!handle) {
            detail::throwOrAbort(message);
        }
        return handle;
    }

    void reset() {
        if (owns_ && handle_) {
            etch_value_free(handle_);
        }
        handle_ = nullptr;
        owns_ = false;
    }

    EtchValue handle_ = nullptr;
    bool owns_ = false;
};

/** Lightweight non-owning context view used in host callbacks */
class ContextView {
public:
    explicit ContextView(EtchContext ctx) : ctx_(ctx) {}

    EtchContext handle() const { return ctx_; }

    Value callFunction(std::string_view name, std::span<const Value> args = {}) const;

    template <typename... Args>
    Value callFunction(std::string_view name, Args&&... args) const;

    Value callFunction(const std::string& name, const std::vector<Value>& args) const;

    void setGlobal(std::string_view name, const Value& value) const;
    Value getGlobal(std::string_view name) const;
    bool hasGlobal(std::string_view name) const;

private:
    EtchContext ctx_ = nullptr;
};

namespace detail {

template <typename T>
struct dependent_false : std::false_type {};

template <typename T>
struct is_optional : std::false_type {};

template <typename U>
struct is_optional<std::optional<U>> : std::true_type {};

inline std::string copyString(std::string_view sv) {
    return std::string(sv);
}

inline Value invokeFunction(EtchContext ctx, std::string_view name, std::span<const Value> args) {
    std::string nameCopy = copyString(name);
    std::vector<EtchValue> raw;
    raw.reserve(args.size());
    for (const auto& arg : args) {
        raw.push_back(arg.handle());
    }
    EtchValue result = etch_call_function(ctx, nameCopy.c_str(), raw.empty() ? nullptr : raw.data(), static_cast<int>(raw.size()));
    if (!result) {
        const char* err = etch_get_error(ctx);
        throwOrAbort(err ? err : "Function call failed");
    }
    return Value(result);
}

inline void setGlobalImpl(EtchContext ctx, std::string_view name, const Value& value) {
    std::string copy = copyString(name);
    etch_set_global(ctx, copy.c_str(), value.handle());
}

inline Value getGlobalImpl(EtchContext ctx, std::string_view name) {
    std::string copy = copyString(name);
    EtchValue v = etch_get_global(ctx, copy.c_str());
    if (!v) {
        throwOrAbort("Global variable not found: " + std::string(name));
    }
    return Value(v);
}

inline bool hasGlobalImpl(EtchContext ctx, std::string_view name) {
    std::string copy = copyString(name);
    EtchValue v = etch_get_global(ctx, copy.c_str());
    if (v) {
        etch_value_free(v);
        return true;
    }
    return false;
}

template <typename T>
Value makeValue(T&& value) {
    using Decayed = std::decay_t<T>;
    if constexpr (std::is_same_v<Decayed, Value>) {
        if constexpr (std::is_lvalue_reference_v<T>) {
            return Value::borrow(value.handle());
        } else {
            return std::move(value);
        }
    } else if constexpr (std::is_same_v<Decayed, std::string>) {
        return Value(value);
    } else if constexpr (std::is_same_v<Decayed, std::string_view>) {
        return Value(value);
    } else if constexpr (std::is_same_v<Decayed, const char*> || std::is_same_v<Decayed, char*>) {
        return Value(value);
    } else if constexpr (std::is_same_v<Decayed, bool>) {
        return Value(static_cast<bool>(value));
    } else if constexpr (std::is_integral_v<Decayed>) {
        return Value(static_cast<int64_t>(value));
    } else if constexpr (std::is_floating_point_v<Decayed>) {
        return Value(static_cast<double>(value));
    } else if constexpr (std::is_same_v<Decayed, std::span<const Value>>) {
        return Value::array(value);
    } else if constexpr (std::is_same_v<Decayed, std::vector<Value>>) {
        return Value::array(std::span<const Value>(value.data(), value.size()));
    } else if constexpr (is_optional<Decayed>::value) {
        if (!value) {
            return Value::none();
        }
        auto inner = makeValue(*value);
        return Value::some(inner);
    } else {
        static_assert(dependent_false<T>::value, "Unsupported Etch argument type");
    }
}

template <typename... Args>
std::vector<Value> packValues(Args&&... args) {
    std::vector<Value> values;
    values.reserve(sizeof...(Args));
    (values.emplace_back(makeValue(std::forward<Args>(args))), ...);
    return values;
}

template <typename T, typename Enable = void>
struct ArgConverter;

template <>
struct ArgConverter<const Value&> {
    static const Value& convert(const Value& v) { return v; }
};

template <>
struct ArgConverter<Value> {
    static Value convert(const Value& v) { return v.clone(); }
};

template <>
struct ArgConverter<char> {
    static char convert(const Value& v) { return v.toChar(); }
};

template <typename T>
struct ArgConverter<T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool>>> {
    static T convert(const Value& v) { return static_cast<T>(v.toInt()); }
};

template <typename T>
struct ArgConverter<T, std::enable_if_t<std::is_floating_point_v<T>>> {
    static T convert(const Value& v) { return static_cast<T>(v.toFloat()); }
};

template <>
struct ArgConverter<bool> {
    static bool convert(const Value& v) { return v.toBool(); }
};

template <>
struct ArgConverter<std::string> {
    static std::string convert(const Value& v) { return v.toString(); }
};

template <>
struct ArgConverter<std::string_view> {
    static std::string_view convert(const Value& v) { return v.toStringView(); }
};

template <typename Fn>
struct FunctionTraits : FunctionTraits<decltype(&Fn::operator())> {};

template <typename R, typename... Args>
struct FunctionTraits<R(*)(Args...)> {
    using ReturnType = R;
    using ArgsTuple = std::tuple<Args...>;
    static constexpr size_t ArgCount = sizeof...(Args);
};

template <typename C, typename R, typename... Args>
struct FunctionTraits<R(C::*)(Args...)> : FunctionTraits<R(*)(Args...)> {};

template <typename C, typename R, typename... Args>
struct FunctionTraits<R(C::*)(Args...) const> : FunctionTraits<R(*)(Args...)> {};

template <typename C, typename R, typename... Args>
struct FunctionTraits<R(C::*)(Args...) noexcept> : FunctionTraits<R(*)(Args...)> {};

template <typename C, typename R, typename... Args>
struct FunctionTraits<R(C::*)(Args...) const noexcept> : FunctionTraits<R(*)(Args...)> {};

template <typename T>
struct IsContextArg : std::false_type {};

template <>
struct IsContextArg<ContextView&> : std::true_type {};

template <>
struct IsContextArg<const ContextView&> : std::true_type {};

template <typename R, typename Enable = void>
struct ReturnConverter;

template <typename R>
struct ReturnConverter<R, std::enable_if_t<!std::is_void_v<R> && !std::is_same_v<std::decay_t<R>, Value>>> {
    static Value convert(R&& value) {
        return makeValue(std::forward<R>(value));
    }
};

template <>
struct ReturnConverter<void, void> {
    static Value convert() { return Value(); }
};

template <>
struct ReturnConverter<Value, void> {
    static Value convert(Value&& value) { return std::move(value); }
};

template <>
struct ReturnConverter<const Value&, void> {
    static Value convert(const Value& value) { return value.clone(); }
};

class HostFunctionStubBase {
public:
    virtual ~HostFunctionStubBase() = default;
    virtual Value invoke(EtchContext ctx, EtchValue* args, int numArgs) = 0;

    static EtchValue dispatch(EtchContext ctx, EtchValue* args, int numArgs, void* userData) {
        auto* stub = static_cast<HostFunctionStubBase*>(userData);
        if (!stub) {
            return nullptr;
        }

#if ETCH_CPP_EXCEPTIONS
        try {
#endif

            Value result = stub->invoke(ctx, args, numArgs);
            return result.release();

#if ETCH_CPP_EXCEPTIONS
        } catch (const Exception& e) {
            std::fprintf(stderr, "[etch] host function exception: %s\n", e.what());
        } catch (const std::exception& e) {
            std::fprintf(stderr, "[etch] host function terminated: %s\n", e.what());
        } catch (...) {
            std::fprintf(stderr, "[etch] host function terminated: unknown exception\n");
        }
        return nullptr;
#endif
    }
};

template <typename Fn>
class HostFunctionStub : public HostFunctionStubBase {
public:
    explicit HostFunctionStub(Fn&& fn) : fn_(std::forward<Fn>(fn)) {}

    Value invoke(EtchContext ctx, EtchValue* args, int numArgs) override {
        std::vector<Value> borrowed;
        borrowed.reserve(numArgs);
        for (int i = 0; i < numArgs; ++i) {
            borrowed.emplace_back(Value::borrow(args[i]));
        }
        ContextView view(ctx);
        return invokeImpl(view, borrowed);
    }

private:
    using Traits = FunctionTraits<std::decay_t<Fn>>;
    using ArgsTuple = typename Traits::ArgsTuple;
    using ReturnType = typename Traits::ReturnType;

    template <typename Callable = Fn>
    Value invokeImpl(ContextView& view, const std::vector<Value>& borrowed) {
        std::span<const Value> span(borrowed.data(), borrowed.size());
        if constexpr (std::is_invocable_v<Callable, ContextView&, std::span<const Value>>) {
            return ReturnConverter<ReturnType>::convert(fn_(view, span));
        } else if constexpr (std::is_invocable_v<Callable, std::span<const Value>>) {
            return ReturnConverter<ReturnType>::convert(fn_(span));
        } else {
            return invokeTyped(view, span);
        }
    }

    template <typename Callable = Fn>
    Value invokeTyped(ContextView& view, std::span<const Value> span) {
        constexpr size_t argCount = std::tuple_size_v<ArgsTuple>;
        constexpr bool takesContext = argCount > 0 && IsContextArg<std::tuple_element_t<0, ArgsTuple>>::value;
        constexpr size_t valueArgs = takesContext ? (argCount - 1) : argCount;

        if (span.size() != valueArgs) {
            throwOrAbort("Host function argument count mismatch");
        }

        return invokeTypedImpl(view, span, std::make_index_sequence<valueArgs>{});
    }

    template <size_t... Indices>
    Value invokeTypedImpl(ContextView& view, std::span<const Value> span, std::index_sequence<Indices...>) {
        constexpr size_t argCount = std::tuple_size_v<ArgsTuple>;
        constexpr bool takesContext = argCount > 0 && IsContextArg<std::tuple_element_t<0, ArgsTuple>>::value;
        if constexpr (takesContext) {
            return ReturnConverter<ReturnType>::convert(
                fn_(view, ArgConverter<std::tuple_element_t<Indices + 1, ArgsTuple>>::convert(span[Indices])...));
        } else {
            return ReturnConverter<ReturnType>::convert(
                fn_(ArgConverter<std::tuple_element_t<Indices, ArgsTuple>>::convert(span[Indices])...));
        }
    }

    Fn fn_;
};

} // namespace detail

inline Value ContextView::callFunction(std::string_view name, std::span<const Value> args) const {
    return detail::invokeFunction(ctx_, name, args);
}

template <typename... Args>
Value ContextView::callFunction(std::string_view name, Args&&... args) const {
    auto owned = detail::packValues(std::forward<Args>(args)...);
    return callFunction(name, std::span<const Value>(owned.data(), owned.size()));
}

inline Value ContextView::callFunction(const std::string& name, const std::vector<Value>& args) const {
    return callFunction(std::string_view{name}, std::span<const Value>(args.data(), args.size()));
}

inline void ContextView::setGlobal(std::string_view name, const Value& value) const {
    detail::setGlobalImpl(ctx_, name, value);
}

inline Value ContextView::getGlobal(std::string_view name) const {
    return detail::getGlobalImpl(ctx_, name);
}

inline bool ContextView::hasGlobal(std::string_view name) const {
    return detail::hasGlobalImpl(ctx_, name);
}

/** Host function signature that receives a span of values */
using HostFunction = std::function<Value(std::span<const Value>)>;

/** Owning Etch context */
class Context {
public:
    Context()
        : ctx_(etch_context_new()) {
        if (!ctx_) {
            detail::throwOrAbort("Failed to create Etch context");
        }
    }

    Context(bool verbose, bool debug) {
        EtchContextOptions opts{verbose ? 1 : 0, debug ? 1 : 0, 0};
        ctx_ = etch_context_new_with_options(&opts);
        if (!ctx_) {
            detail::throwOrAbort("Failed to create Etch context");
        }
    }

    ~Context() {
        if (ctx_) {
            etch_context_free(ctx_);
        }
    }

    Context(const Context&) = delete;
    Context& operator=(const Context&) = delete;

    Context(Context&& other) noexcept
        : ctx_(other.ctx_), hostStubs_(std::move(other.hostStubs_)) {
        other.ctx_ = nullptr;
    }

    Context& operator=(Context&& other) noexcept {
        if (this != &other) {
            if (ctx_) {
                etch_context_free(ctx_);
            }
            ctx_ = other.ctx_;
            hostStubs_ = std::move(other.hostStubs_);
            other.ctx_ = nullptr;
        }
        return *this;
    }

    void setVerbose(bool verbose) {
        etch_context_set_verbose(ctx_, verbose ? 1 : 0);
    }

    void compileString(std::string_view source, std::string_view filename = "<string>") {
        std::string srcCopy(source);
        std::string fileCopy(filename);
        if (etch_compile_string(ctx_, srcCopy.c_str(), fileCopy.c_str()) != 0) {
            const char* err = etch_get_error(ctx_);
            detail::throwOrAbort(err ? err : "Compilation failed");
        }
    }

    void compileFile(std::string_view path) {
        std::string pathCopy(path);
        if (etch_compile_file(ctx_, pathCopy.c_str()) != 0) {
            const char* err = etch_get_error(ctx_);
            detail::throwOrAbort(err ? err : "Failed to compile file");
        }
    }

    int execute() {
        int result = etch_execute(ctx_);
        if (result != 0) {
            const char* err = etch_get_error(ctx_);
            if (err) {
                detail::throwOrAbort(err);
            }
        }
        return result;
    }

    Value callFunction(std::string_view name, std::span<const Value> args) {
        return detail::invokeFunction(ctx_, name, args);
    }

    template <typename... Args>
    Value callFunction(std::string_view name, Args&&... args) {
        auto owned = detail::packValues(std::forward<Args>(args)...);
        return callFunction(name, std::span<const Value>(owned.data(), owned.size()));
    }

    Value callFunction(const std::string& name, const std::vector<Value>& args = {}) {
        return callFunction(std::string_view{name}, std::span<const Value>(args.data(), args.size()));
    }

    void setGlobal(std::string_view name, const Value& value) {
        detail::setGlobalImpl(ctx_, name, value);
    }

    Value getGlobal(std::string_view name) {
        return detail::getGlobalImpl(ctx_, name);
    }

    bool hasGlobal(std::string_view name) const {
        return detail::hasGlobalImpl(ctx_, name);
    }

    void registerFunction(std::string_view name, EtchHostFunction callback, void* userData = nullptr) {
        std::string copy = detail::copyString(name);
        if (etch_register_function(ctx_, copy.c_str(), callback, userData) != 0) {
            detail::throwOrAbort("Failed to register host function: " + std::string(name));
        }
    }

    template <typename Fn>
    void registerFunction(std::string_view name, Fn&& fn) {
        using Stub = detail::HostFunctionStub<std::decay_t<Fn>>;
        auto stub = std::make_unique<Stub>(std::forward<Fn>(fn));
        auto* stubPtr = stub.get();
        std::string copy = detail::copyString(name);
        if (etch_register_function(ctx_, copy.c_str(), &detail::HostFunctionStubBase::dispatch, stubPtr) != 0) {
            detail::throwOrAbort("Failed to register host function: " + std::string(name));
        }
        hostStubs_.push_back(std::move(stub));
    }

    EtchContext handle() const { return ctx_; }

private:
    EtchContext ctx_ = nullptr;
    std::vector<std::unique_ptr<detail::HostFunctionStubBase>> hostStubs_;
};

} // namespace etch

#endif // ETCH_HPP
