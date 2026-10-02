# Kept apart from shims.rb because compiled_run.rb also feeds this file to bc2cpp (ADR 0305).
unless 0.respond_to?(:[])
  class Integer
    def [](i)
      (self >> i) & 1
    end
  end
end
