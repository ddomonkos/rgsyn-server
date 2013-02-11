require 'ohm'
require 'digest/sha2'

module Rgsyn

  class User < Ohm::Model

    attribute :username
    unique :username
    attribute :rights
    
    #these should not be accessed directly (from outside)
    attribute :_pw_hash
    attribute :_salt
    
    # Access level constants
    ADMIN = 10
    REGULAR = 5
    RESTRICTED = 1
    ANY = 0
    
    def self.create(p)
      password = p.delete(:password) #acts as a virtual _password_ attribute
      salt = (0...15).map{ ('a'..'z').to_a[rand(26)] }.join
      super(p.merge(:_pw_hash => User.pw_digest(password, salt),
                    :_salt => salt))
    end
    
    def update(p)
      password = p.delete(:password) #acts as a virtual _password_ attribute
      super(p.merge(:_pw_hash => User.pw_digest(password, _salt)))
    end
    
    # Assigns a new password. The _password_ acts as a virtual attribute,
    # in reality it is hashed first.
    #
    def password=(value)
      _pw_hash = User.pw_digest(value, _salt)
    end
    
    # The only way to compare passwords, since password accessor does not
    # (cannot) exist.
    #
    def auth?(password)
      _pw_hash == User.pw_digest(password, _salt)
    end
    
    # String representation of given rights.
    #
    def rights_s
      case rights.to_i
      when ADMIN then 'admin'
      when REGULAR then 'regular'
      when RESTRICTED then 'restricted'
      else 'unknown'
      end
    end
    
    def self.parse_rights(rights)
      case rights
      when 'admin' then ADMIN
      when 'regular' then REGULAR
      when 'restricted' then RESTRCITED
      else raise 'Illegal rights!'
      end
    end
    
    private
    
    # Create hash from password, using provided salt.
    #
    def self.pw_digest(password, salt)
      (Digest::SHA2.new << password << salt).to_s
    end
    
  end
  
end
