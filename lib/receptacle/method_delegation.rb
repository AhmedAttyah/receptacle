# frozen_string_literal: true

require "receptacle/method_cache"
require "receptacle/registration"
require "receptacle/errors"
module Receptacle
  # module which enables a repository to mediate methods dynamically to wrappers and strategy
  # @api private
  module MethodDelegation
    # dynamically build mediation method on first invocation if the method is registered
    def method_missing(method_name, *args, **kwargs, &block)
      if Registration.repositories[self].methods.include?(method_name)
        public_send(__build_method(method_name), *args, **kwargs, &block)
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      Registration.repositories[self].methods.include?(method_name) || super
    end

    # @param method_name [#to_sym]
    # @return [void]
    def __build_method(method_name)
      method_cache = __build_method_call_cache(method_name)
      if method_cache.wrappers.nil? || method_cache.wrappers.empty?
        __define_shortcut_method(method_cache)
      else
        __define_full_method(method_cache)
      end
    end

    # build method cache for given method name
    # @param method_name [#to_sym]
    # @return [MethodCache]
    def __build_method_call_cache(method_name)
      config = Registration.repositories[self]

      raise Errors::NotConfigured.new(repo: self) if config.strategy.nil?

      MethodCache.new(
        strategy: config.strategy,
        wrappers: config.wrappers,
        method_name: method_name
      )
    end

    # build lightweight method to mediate method calls to strategy without wrappers
    # @param method_cache [MethodCache] method_cache of the method to be build
    # @return [void]
    def __define_shortcut_method(method_cache)
      define_singleton_method(method_cache.method_name) do |*args, **kwargs, &inner_block|
        if kwargs.empty?
          method_cache.strategy.new.public_send(method_cache.method_name, *args, &inner_block)
        else
          method_cache.strategy.new.public_send(method_cache.method_name, *args, **kwargs, &inner_block)
        end
      end
    end

    # build method to mediate method calls to strategy with full wrapper support
    # @param method_cache [MethodCache] method_cache of the method to be build
    # @return [void]
    def __define_full_method(method_cache)
      define_singleton_method(method_cache.method_name) do |*args, **kwargs, &inner_block|
        __run_wrappers(method_cache, args, kwargs) do |*call_args, **kwargs|
          if kwargs.empty?
            method_cache.strategy.new.public_send(method_cache.method_name, *call_args, &inner_block)
          else
            method_cache.strategy.new.public_send(method_cache.method_name, *call_args, **kwargs, &inner_block)
          end
        end
      end
    end

    # runtime method to call before and after wrapper in correct order
    # @param method_cache [MethodCache] method_cache for the current method
    # @param input_args input parameter of the repository method call
    # @return strategy method return value after all wrappers where applied
    def __run_wrappers(method_cache, input_args, kwargs)
      wrappers = method_cache.wrappers.map(&:new)
      all_args = { args: input_args, kwargs: kwargs}
      unless method_cache.skip_before_wrappers?
        all_args = __run_before_wrappers(wrappers, method_cache.before_method_name, all_args)
      end

      ret = yield(*(all_args[:args]), **(all_args[:kwargs]))
      return ret if method_cache.skip_after_wrappers?

      __run_after_wrappers(wrappers, method_cache.after_method_name, all_args, ret)
    end

    # runtime method to execute all before wrappers
    # @param wrappers [Array] all wrapper instances to be executed
    # @param method_name [Symbol] name of method to be executed on wrappers
    # @param args input args of the repository method
    # @return processed method args by before wrappers
    def __run_before_wrappers(wrappers, method_name, all_args)
      wrappers.each do |wrapper|
        next unless wrapper.respond_to?(method_name)
        all_args = if all_args[:kwargs].empty?
          wrapper.public_send(method_name, *(all_args[:args]))
        else
          wrapper.public_send(method_name, *(all_args[:args]), **all_args[:kwargs])
        end

        unless all_args.is_a?(Hash) and all_args.keys == [:args, :kwargs]
          raise Errors::BeforeWrapperReturnError.new("wrapper before_* method must return"\
                "a hash with the following structure {args: [], kwargs: {}}")
        end
      end
      all_args
    end

    # runtime method to execute all after wrappers
    # @param wrappers [Array] all wrapper instances to be executed
    # @param method_name [Symbol] name of method to be executed on wrappers
    # @param args input args to the strategy method (after processing in before wrappers)
    # @param return_value return value of strategy method
    # @return processed return value by all after wrappers
    def __run_after_wrappers(wrappers, method_name, all_args, return_value)
      wrappers.reverse_each do |wrapper|
        next unless wrapper.respond_to?(method_name)
        return_value =  if all_args[:kwargs].empty?
          wrapper.public_send(method_name, return_value, *all_args[:args])
        else
          wrapper.public_send(method_name, return_value, *all_args[:args], **all_args[:kwargs])
        end
      end
      return_value
    end
  end
end
